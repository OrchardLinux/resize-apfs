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
#endif
