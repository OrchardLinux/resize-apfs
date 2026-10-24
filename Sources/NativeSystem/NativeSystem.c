#include "NativeSystem.h"
#include <TargetConditionals.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dlfcn.h>
#include <spawn.h>
#include <signal.h>
#include <string.h>
#include <limits.h>
#include <stdio.h>
#include <ctype.h>

// Darwin disk ioctl ABI, also published in XNU's BSD sys/disk.h.
#define RAF_GET_BLOCK_SIZE _IOR('d', 24, uint32_t)
#define RAF_GET_BLOCK_COUNT _IOR('d', 25, uint64_t)
#define RAF_SYNC_CACHE _IO('d', 22)

static int valid_path(const char *path, int fixture) {
    struct stat st;
    if (fixture) {
        if (lstat(path, &st) || !S_ISREG(st.st_mode)) { errno = EINVAL; return 0; }
        return 1;
    }
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    (void)path; errno = ENOTSUP; return 0; // Never open a host disk.
#else
    if (strcmp(path, "/dev/disk0") && strcmp(path, "/dev/rdisk0")) { errno = EINVAL; return 0; }
    if (geteuid() != 0) { errno = EPERM; return 0; }
    if (lstat(path, &st) || !(S_ISBLK(st.st_mode) || S_ISCHR(st.st_mode))) { errno = ENODEV; return 0; }
    return 1;
#endif
}
int raf_open_read(const char *path, int fixture) {
    if (!valid_path(path, fixture)) return -1;
    return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
}
int raf_open_gpt_write(const char *path, int fixture) {
    if (!valid_path(path, fixture)) return -1;
    if (fixture) return open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK);
    // Same shared-lock open mechanism as GPT fdisk's Darwin DiskIO fallback.
    // No O_CREAT, truncation, unmount, repair or whole-disk formatting.
    return open(path, O_WRONLY | O_SHLOCK | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
}
int raf_geometry(int fd, uint32_t *sector, uint64_t *blocks) {
    if (ioctl(fd, RAF_GET_BLOCK_SIZE, sector) || ioctl(fd, RAF_GET_BLOCK_COUNT, blocks)) return -1;
    return 0;
}
int raf_flush(int fd, int fixture) {
    if (fixture) return fsync(fd);
    if (fsync(fd) && errno != EINVAL && errno != ENOTSUP) return -1;
    return ioctl(fd, RAF_SYNC_CACHE);
}
static void *apfs(void) {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    errno = ENOTSUP; return NULL; // Do not invoke macOS APFS mutation APIs in tests.
#else
    return dlopen("/System/Library/PrivateFrameworks/APFS.framework/APFS", RTLD_LOCAL | RTLD_LAZY);
#endif
}
int raf_apfs_minimum(const char *bsd, int64_t *bytes) {
    void *handle = apfs(); if (!handle) return ENOTSUP;
    // Signature recorded in palera1n/jbinit's private APFS header (CFIndex*).
    int (*fn)(const char *, intptr_t *) = dlsym(handle, "APFSContainerGetMinimalSize");
    intptr_t result = 0;
    int status = fn ? fn(bsd, &result) : ENOSYS;
    if (!status && result > 0) *bytes = (int64_t)result;
    else if (!status) status = EINVAL;
    dlclose(handle); return status;
}
int raf_apfs_resize(const char *bsd, uint64_t bytes) {
    void *handle = apfs(); if (!handle) return ENOTSUP;
    int (*fn)(const char *, uint64_t) = dlsym(handle, "APFSContainerResize");
    int status = fn ? fn(bsd, bytes) : ENOSYS;
    dlclose(handle); return status;
}
int raf_partition_capacity(const char *bsd, uint64_t *bytes) {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    (void)bsd; (void)bytes; return ENOTSUP;
#else
    if (strncmp(bsd, "disk0s", 6) || !bsd[6] || strlen(bsd) > 16) return EINVAL;
    for (const char *p = bsd + 6; *p; ++p) if (!isdigit((unsigned char)*p)) return EINVAL;
    char path[32]; snprintf(path, sizeof(path), "/dev/%s", bsd);
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno;
    uint32_t sector = 0; uint64_t blocks = 0;
    int result = raf_geometry(fd, &sector, &blocks) ? errno : 0;
    close(fd);
    if (!result && sector && blocks <= UINT64_MAX / sector) *bytes = blocks * sector;
    else if (!result) result = EOVERFLOW;
    return result;
#endif
}
int raf_spawn_worker(const char *executable, const char *job, pid_t *pid, int *release_fd) {
    int gate[2];
    if (pipe(gate)) return errno;
    fcntl(gate[0], F_SETFD, FD_CLOEXEC); fcntl(gate[1], F_SETFD, FD_CLOEXEC);
    // Keep the source descriptor away from child fd 3 and the standard streams.
    int read_fd = fcntl(gate[0], F_DUPFD_CLOEXEC, 10);
    close(gate[0]);
    if (read_fd < 0) { int error = errno; close(gate[1]); return error; }
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int status = posix_spawnattr_init(&attr);
    if (status) { close(read_fd); close(gate[1]); return status; }
    status = posix_spawn_file_actions_init(&actions);
    if (status) { posix_spawnattr_destroy(&attr); close(read_fd); close(gate[1]); return status; }
    posix_spawn_file_actions_adddup2(&actions, read_fd, 3);
    posix_spawn_file_actions_addclose(&actions, read_fd);
    if (gate[1] != 3) posix_spawn_file_actions_addclose(&actions, gate[1]);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    char *const argv[] = {(char *)executable, "--worker", (char *)job, "--gate-fd", "3", NULL};
    char *const env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    status = posix_spawn(pid, executable, &actions, &attr, argv, env);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
    close(read_fd);
    if (status) close(gate[1]); else *release_fd = gate[1];
    return status;
}
int raf_release_worker(int fd) {
    char value = 'G'; ssize_t n;
    do { n = write(fd, &value, 1); } while (n < 0 && errno == EINTR);
    return n == 1 ? 0 : -1;
}
int raf_wait_for_release(int fd) {
    char value = 0; ssize_t n;
    do { n = read(fd, &value, 1); } while (n < 0 && errno == EINTR);
    return n == 1 && value == 'G' ? 0 : -1;
}
int raf_poll_worker(pid_t pid, int *exit_status) {
    int status = 0;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0) return 0;
    if (result < 0) return -1;
    *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    return 1;
}
int raf_peer_uid(int fd, uid_t *uid) {
    gid_t group;
    return getpeereid(fd, uid, &group);
}
int raf_peer_is_executable(int fd, const char *expected_path) {
    pid_t pid = 0; socklen_t size = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) || pid <= 0) return 0;
    int (*pidpath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
    if (!pidpath) return 0;
    char path[4096] = {0};
    if (pidpath(pid, path, sizeof(path)) <= 0) return 0;
    return strcmp(path, expected_path) == 0;
}
