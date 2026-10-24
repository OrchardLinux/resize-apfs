// Starts our separately supervised job, then preserves palera1n's own daemon.
// No network listener, bootstrap/package-manager install, or disk command.
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
extern char **environ;
int main(void) {
    pid_t pid = 0;
    char *const bootstrap[] = {"/cores/binpack/bin/launchctl", "bootstrap", "system",
        "/cores/binpack/Library/LaunchDaemons/dev.omarchy.resize-apfs.plist", NULL};
    int result = posix_spawn(&pid, bootstrap[0], NULL, NULL, bootstrap, environ);
    if (!result) {
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        fprintf(stderr, "Resize APFS launchd bootstrap status: %d\n", status);
    } else fprintf(stderr, "Resize APFS launchd bootstrap failed: %d\n", result);
    char *const original[] = {"/cores/binpack/usr/sbin/palera1nd", NULL};
    execve(original[0], original, environ);
    perror("exec original palera1nd");
    return 1;
}
