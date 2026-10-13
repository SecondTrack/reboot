// rbhelper — setuid-root Helfer des Reboot Appstore. Installiert oder entfernt NUR Reboot-Apps (Paket "de.mesh.*").
//
//   rbhelper install /var/mobile/Library/Reboot/dl/<name>.deb
//   rbhelper remove  de.mesh.<paket>
//
// Wird mit chown root:wheel + chmod 4755 ins App-Bundle gelegt (postinst). Weil jeder lokale Prozess ihn
// aufrufen kann, ist er bewusst eng:
//   - nur Dateien aus dem Download-Ordner des Stores (kein Symlink, echte .deb-Datei)
//   - das Paket wird ZUERST in einen nur-Root-Ordner kopiert und erst dort geprüft und installiert
//     (sonst könnte jemand die Datei zwischen Prüfung und Installation austauschen)
//   - nur Paketnamen "de.mesh.*", feste Programmpfade, leere Umgebung
// Exit-Codes: 0 ok, 2 Aufruf falsch, 3 keine Root-Rechte, 4 Datei abgelehnt, 5 Paket abgelehnt, 6 dpkg-Fehler
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/sysctl.h>

#define DLDIR   "/var/mobile/Library/Reboot/dl/"
#define WORKDIR "/var/root/.reboot"
#define DPKG    "/usr/bin/dpkg"
#define DPKGDEB "/usr/bin/dpkg-deb"
#define UICACHE "/usr/bin/uicache"
#define MOBILE  501
#define LOGFILE WORKDIR "/dpkg.log"
#define SELF    "/Applications/Shop.app/rbhelper"   // Ausgabe von dpkg (nicht an den Store gebunden: der darf währenddessen enden)

static char *ENV[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", NULL };

// Paketname: "de.mesh." + Kleinbuchstaben/Ziffern/.+- , höchstens 64 Zeichen
static int validPkg(const char *p) {
    size_t n = strlen(p);
    if (n < 9 || n > 64 || strncmp(p, "de.mesh.", 8) != 0) return 0;
    for (size_t i = 8; i < n; i++) {
        char c = p[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '+' || c == '-')) return 0;
    }
    return 1;
}

// Programm starten und warten; optional stdout in buf lesen
static int run(char *const argv[], char *buf, size_t bufLen) {
    int fd[2] = { -1, -1 };
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    if (buf) {
        if (pipe(fd) != 0) return -1;
        posix_spawn_file_actions_adddup2(&fa, fd[1], 1);
        posix_spawn_file_actions_addclose(&fa, fd[0]);
        posix_spawn_file_actions_addopen(&fa, 2, LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0600);
    } else {
        posix_spawn_file_actions_addopen(&fa, 1, LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0600);
        posix_spawn_file_actions_adddup2(&fa, 1, 2);
    }
    pid_t pid; int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, ENV);
    posix_spawn_file_actions_destroy(&fa);
    if (buf) {
        close(fd[1]);
        size_t got = 0; ssize_t r;
        while (rc == 0 && got + 1 < bufLen && (r = read(fd[0], buf + got, bufLen - 1 - got)) > 0) got += (size_t)r;
        buf[got] = 0; close(fd[0]);
    }
    if (rc != 0) return -1;
    int st = 0; while (waitpid(pid, &st, 0) < 0) {}
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

// Icon-Cache von SpringBoard als Nutzer "mobile" neu aufbauen
static void uicache(void) {
    pid_t pid = fork();
    if (pid == 0) {
        if (setgid(MOBILE) != 0 || setuid(MOBILE) != 0) _exit(1);
        char *argv[] = { UICACHE, NULL };
        char *env[] = { "PATH=/usr/bin:/bin", "HOME=/var/mobile", NULL };
        execve(UICACHE, argv, env); _exit(1);
    }
    if (pid > 0) { int st; waitpid(pid, &st, 0); }
}

// Datei byteweise kopieren (Ziel neu, nur Root lesbar)
static int copyFile(const char *from, const char *to) {
    int in = open(from, O_RDONLY | O_NOFOLLOW); if (in < 0) return -1;
    struct stat st; if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 200L*1024*1024) { close(in); return -1; }
    unlink(to);
    int out = open(to, O_WRONLY | O_CREAT | O_EXCL, 0600); if (out < 0) { close(in); return -1; }
    char b[65536]; ssize_t r; int ok = 0;
    while ((r = read(in, b, sizeof b)) > 0) if (write(out, b, (size_t)r) != r) { ok = -1; break; }
    if (r < 0) ok = -1;
    close(in); close(out); return ok;
}

// Ist das Paket wirklich fertig installiert? (dpkg-Status "install ok installed")
static int installedOK(const char *pkg) {
    char st[128] = {0};
    char *q[] = { "/usr/bin/dpkg-query", "-W", "-f=${Status}", (char *)pkg, NULL };
    if (run(q, st, sizeof st) != 0) return 0;
    return strstr(st, "install ok installed") != NULL;
}

// Alle laufenden Programme eines Pakets beenden (App + Hintergrundprozesse wie Tor), bevor es ersetzt
// oder entfernt wird – sonst laufen alte Prozesse weiter und blockieren z.B. ihre Datenordner.
static void stopPackage(const char *pkg) {
    char list[16384] = {0};
    char *q[] = { "/usr/bin/dpkg-query", "-L", (char *)pkg, NULL };
    if (run(q, list, sizeof list) != 0) return;
    char names[32][32]; int n = 0;
    for (char *line = strtok(list, "\n"); line && n < 32; line = strtok(NULL, "\n")) {
        if (strncmp(line, "/Applications/", 14) != 0) continue;
        struct stat st;
        if (lstat(line, &st) != 0 || !S_ISREG(st.st_mode) || !(st.st_mode & S_IXUSR)) continue;   // nur ausführbare Dateien
        const char *b = strrchr(line, '/'); if (!b) continue; b++;
        if (!strcmp(b, "rbhelper")) continue;                                                      // sich selbst nicht
        // Mesh-Tor weiterlaufen lassen: es liest nach jedem Neustart ~30 MB Netzverzeichnis ein (am iPod
        // eine Minute). Das laufende Programm behält die alte Datei; Mesh startet es bei Bedarf selbst.
        if (!strcmp(b, "mesh-tor")) continue;
        strncpy(names[n], b, 16); names[n][16] = 0; n++;                                            // p_comm ist max. 16 Zeichen
    }
    if (!n) return;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 }; size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || !len) return;
    struct kinfo_proc *procs = malloc(len); if (!procs) return;
    if (sysctl(mib, 3, procs, &len, NULL, 0) == 0) {
        int cnt = (int)(len / sizeof(struct kinfo_proc));
        for (int sig = 0; sig < 2; sig++) {
            for (int i = 0; i < cnt; i++) for (int k = 0; k < n; k++)
                if (!strcmp(procs[i].kp_proc.p_comm, names[k]) && procs[i].kp_proc.p_pid > 1) kill(procs[i].kp_proc.p_pid, sig ? SIGKILL : SIGTERM);
            if (!sig) sleep(2);                                                                     // erst höflich, dann hart
        }
    }
    free(procs);
}

// Eigene Rechte sichern: nach einem (Selbst-)Update des Stores muss der Helfer wieder root + setuid sein,
// auch wenn das postinst-Skript nicht (vollständig) gelaufen ist
static void keepSelf(void) {
    struct stat st;
    if (lstat(SELF, &st) == 0 && S_ISREG(st.st_mode)) { chown(SELF, 0, 0); chmod(SELF, 04755); }
}

static int install(const char *path) {
    // 1) nur echte .deb-Dateien direkt im Download-Ordner
    // realpath löst /var zu /private/var auf (iOS) -> beide Formen akzeptieren
    char real[PATH_MAX];
    if (!realpath(path, real)) return 4;
    const char *rest = NULL;
    if (strncmp(real, DLDIR, strlen(DLDIR)) == 0) rest = real + strlen(DLDIR);
    else if (strncmp(real, "/private" DLDIR, strlen("/private" DLDIR)) == 0) rest = real + strlen("/private" DLDIR);
    if (!rest || !*rest || strchr(rest, '/')) return 4;
    size_t n = strlen(real); if (n < 5 || strcmp(real + n - 4, ".deb") != 0) return 4;
    struct stat ls; if (lstat(real, &ls) != 0 || !S_ISREG(ls.st_mode)) return 4;
    // 2) in einen nur-Root-Ordner kopieren -> ab hier kann niemand mehr tauschen
    mkdir(WORKDIR, 0700); chmod(WORKDIR, 0700);
    char work[] = WORKDIR "/pkg.deb";
    if (copyFile(real, work) != 0) return 4;
    // 3) Paketname aus der Kopie lesen und prüfen
    char name[128] = {0};
    char *q[] = { DPKGDEB, "-f", work, "Package", NULL };
    if (run(q, name, sizeof name) != 0) { unlink(work); return 5; }
    name[strcspn(name, "\r\n")] = 0;
    if (!validPkg(name)) { fprintf(stderr, "Paket abgelehnt: %s\n", name); unlink(work); return 5; }
    if (strcmp(name, "de.mesh.shop") != 0) stopPackage(name);   // laufende alte Version beenden (Store selbst nicht)
    // 4) installieren; danach halbfertige Pakete (z.B. abgebrochene Läufe) fertig einrichten
    // dpkg kann gesperrt sein (zweite Installation läuft) -> bis zu 5x kurz warten und erneut
    char *i[] = { DPKG, "-i", work, NULL };
    char *c[] = { DPKG, "--configure", "-a", NULL };
    for (int t = 0; t < 5; t++) {
        run(i, NULL, 0);
        run(c, NULL, 0);
        keepSelf();
        if (installedOK(name)) break;
        sleep(3);
    }
    unlink(work);
    uicache();
    return installedOK(name) ? 0 : 6;
}

static int removePkg(const char *pkg) {
    if (!validPkg(pkg)) return 5;
    stopPackage(pkg);
    char *r[] = { DPKG, "-r", (char *)pkg, NULL };
    int rc = run(r, NULL, 0);
    uicache();
    return rc == 0 ? 0 : 6;
}

int main(int argc, char **argv) {
    if (setgid(0) != 0 || setuid(0) != 0 || geteuid() != 0) { fprintf(stderr, "keine Root-Rechte (setuid-Bit fehlt?)\n"); return 3; }
    umask(022);
    signal(SIGPIPE, SIG_IGN); signal(SIGHUP, SIG_IGN); signal(SIGTERM, SIG_IGN);   // Store darf während der Installation enden
    mkdir(WORKDIR, 0700); chmod(WORKDIR, 0700);
    if (argc == 3 && strcmp(argv[1], "install") == 0) return install(argv[2]);
    if (argc == 3 && strcmp(argv[1], "remove") == 0) return removePkg(argv[2]);
    fprintf(stderr, "Aufruf: rbhelper install <datei.deb> | remove <paket>\n");
    return 2;
}
