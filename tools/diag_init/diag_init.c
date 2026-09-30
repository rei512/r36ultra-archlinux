// SPDX-License-Identifier: MIT
#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <time.h>

static int kfd = -1;
static char report[65536]; static size_t rlen = 0;

static void klog(const char *fmt, ...) {
    char buf[1024]; va_list ap; va_start(ap, fmt); int n = vsnprintf(buf, sizeof buf - 1, fmt, ap); va_end(ap);
    if (n < 0) return; if (n >= (int)sizeof buf - 1) n = sizeof buf - 2; buf[n] = '\n';
    if (kfd >= 0) write(kfd, buf, n + 1);
    if (rlen + n + 1 < sizeof report) { memcpy(report + rlen, buf, n + 1); rlen += n + 1; }
}

/* 子プロセスを実行し、stdout/stderr を kmsg へ転送、終了状態を報告 */
static void run(const char *tag, char *const argv[], char *const envp[]) {
    int p[2]; if (pipe(p) < 0) { klog("DIAG %s: pipe failed: %d", tag, errno); return; }
    pid_t pid = fork();
    if (pid < 0) { klog("DIAG %s: fork failed: %d", tag, errno); return; }
    if (pid == 0) {
        dup2(p[1], 1); dup2(p[1], 2); close(p[0]); close(p[1]);
        execve(argv[0], argv, envp);
        fprintf(stderr, "execve failed errno=%d\n", errno); _exit(127);
    }
    close(p[1]);
    char line[512]; size_t ll = 0; char c; int lines = 0;
    while (read(p[0], &c, 1) == 1) {
        if (c == '\n' || ll >= sizeof line - 1) { line[ll] = 0; if (lines < 150) klog("DIAG %s> %s", tag, line); lines++; ll = 0; }
        else line[ll++] = c;
    }
    if (ll) { line[ll] = 0; klog("DIAG %s> %s", tag, line); }
    if (lines > 150) klog("DIAG %s> ... (%d lines total)", tag, lines);
    close(p[0]);
    int st = 0; waitpid(pid, &st, 0);
    if (WIFEXITED(st)) klog("DIAG %s: exited status=%d", tag, WEXITSTATUS(st));
    else if (WIFSIGNALED(st)) klog("DIAG %s: killed by signal %d%s", tag, WTERMSIG(st), WCOREDUMP(st) ? " (core)" : "");
    else klog("DIAG %s: wait status=0x%x", tag, st);
}

int main(void) {
    kfd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    klog("DIAG: static init alive (pid=%d, uid=%d)", getpid(), getuid());
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mkdir("/dev/pts", 0755); mount("devpts", "/dev/pts", "devpts", 0, NULL);
    char *env_plain[] = { "PATH=/usr/bin", NULL };
    char *env_auxv[]  = { "PATH=/usr/bin", "LD_SHOW_AUXV=1", NULL };
    char *env_dbg[]   = { "PATH=/usr/bin", "LD_DEBUG=libs,files", NULL };
    char *a_true[]    = { "/usr/bin/true", NULL };
    char *a_ld[]      = { "/usr/lib/ld-linux-aarch64.so.1", "--version", NULL };
    char *a_ld_true[] = { "/usr/lib/ld-linux-aarch64.so.1", "/usr/bin/true", NULL };
    run("true",      a_true, env_plain);
    run("ld.so",     a_ld, env_plain);
    run("auxv",      a_true, env_auxv);
    run("lddebug",   a_ld_true, env_dbg);
    /* 結果を boot パーティションに保存 */
    if (mount("/dev/mmcblk0p1", "/mnt", "vfat", 0, NULL) == 0) {
        int f = open("/mnt/diag.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (f >= 0) { write(f, report, rlen); close(f); klog("DIAG: report written to boot partition /diag.txt (%zu bytes)", rlen); }
        /* カーネルログも保存 */
        int k = open("/dev/kmsg", O_RDONLY | O_NONBLOCK); int o = open("/mnt/kmsg.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (k >= 0 && o >= 0) { char b[8192]; ssize_t n; while ((n = read(k, b, sizeof b)) > 0) write(o, b, n); }
        if (k >= 0) close(k); if (o >= 0) close(o);
        umount("/mnt"); sync();
        klog("DIAG: boot partition unmounted, safe to power off");
    } else klog("DIAG: mount /dev/mmcblk0p1 failed errno=%d", errno);
    for (int t = 0;; t += 30) { klog("DIAG: alive %ds (display should be up; power off when done)", t); sleep(30); }
}
