#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                 unsigned short cols, unsigned short rows, int *master_fd) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0};
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;
    if (pid == 0) {
        // fork 와 exec 사이: async-signal-safe 호출만 쓴다.
        // 데몬이 무시하는 신호(SIGPIPE·SIGHUP 등)는 exec 뒤에도 무시된 채로 넘어가므로 기본값으로 되돌린다.
        int signals[] = {SIGPIPE, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU};
        for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) signal(signals[i], SIG_DFL);
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        // 데몬의 소켓·다른 화면 fd 가 셸로 새지 않게 닫는다.
        int maxfd = getdtablesize();
        for (int fd = 3; fd < maxfd; fd++) close(fd);
        if (cwd == NULL || chdir(cwd) != 0) {
            const char *home = NULL;
            for (char *const *e = envp; e && *e; e++) {
                const char *s = *e;
                if (s[0] == 'H' && s[1] == 'O' && s[2] == 'M' && s[3] == 'E' && s[4] == '=') { home = s + 5; break; }
            }
            if (home == NULL || chdir(home) != 0) chdir("/");
        }
        execve(path, argv, envp);
        _exit(127);
    }
    // 데몬이 나중에 띄우는 다른 셸로 이 fd 가 넘어가지 않게
    fcntl(master, F_SETFD, FD_CLOEXEC);
    int flags = fcntl(master, F_GETFL);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);
    *master_fd = master;
    return pid;
}

pid_t cpty_foreground(int master_fd) {
    return tcgetpgrp(master_fd);
}

int cpty_resize(int master_fd, unsigned short cols, unsigned short rows) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0};
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}
