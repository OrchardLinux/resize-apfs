#ifndef RESIZE_NATIVE_SYSTEM_H
#define RESIZE_NATIVE_SYSTEM_H
#include <stdint.h>
#include <sys/types.h>
int raf_geometry(int fd, uint32_t *sector, uint64_t *blocks);
int raf_open_read(const char *path, int regular_file_fixture);
int raf_open_gpt_write(const char *path, int regular_file_fixture);
int raf_flush(int fd, int regular_file_fixture);
int raf_apfs_minimum(const char *bsd, int64_t *bytes);
int raf_apfs_resize(const char *bsd, uint64_t bytes);
int raf_partition_capacity(const char *bsd, uint64_t *bytes);
int raf_spawn_worker(const char *executable, const char *job, pid_t *pid, int *release_fd);
int raf_release_worker(int fd);
int raf_wait_for_release(int fd);
int raf_poll_worker(pid_t pid, int *exit_status);
int raf_peer_uid(int fd, uid_t *uid);
int raf_peer_is_executable(int fd, const char *expected_path);
/* Snapshots of a mounted APFS volume (adapted from resize-apfs PR #6, da47f156).
   Never act on host volumes: macOS and simulator builds return 0 names / ENOTSUP. */
int raf_list_snapshots(const char *mount_path, char *buffer, size_t buffer_size);
int raf_delete_snapshot(const char *mount_path, const char *name);
int raf_create_snapshot(const char *mount_path, const char *name);
/* 1 when a process whose name starts with `name` (at most 15 characters, as the kernel
   keeps it) runs, 0 when none does, -1 when the process list cannot be read. */
int raf_process_running(const char *name);
#endif
