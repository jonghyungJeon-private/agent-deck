#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/// 새 가상 터미널(pty)을 만들고 그 안에서 path 를 실행한다.
/// 성공하면 자식 pid 를 돌려주고 *master_fd 에 터미널 쪽 fd 를 넣는다. 실패하면 -1 (errno 설정).
/// 자식은 새 세션의 리더가 되고 pty 가 제어 터미널이 된다. 열린 fd 는 0~2 만 넘어간다.
pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                 unsigned short cols, unsigned short rows, int *master_fd);

/// 이 pty 의 지금 앞쪽 프로세스 그룹(셸에서 실행 중인 프로그램). 모르면 -1.
pid_t cpty_foreground(int master_fd);

/// 화면 크기를 바꾼다(앞쪽 프로그램에 SIGWINCH 가 간다).
int cpty_resize(int master_fd, unsigned short cols, unsigned short rows);

#endif
