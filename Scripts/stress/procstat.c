// procstat — a minimal `ps` for a jailbroken device whose bootstrap ships
// none: one line per process whose name matches a filter.
//
//   procstat [-z] [-n interval_s -c count] [name ...]
//
// Columns: pid ppid state footprint_kb resident_kb cpu% name. `state` is Z for
// a zombie (exited, not yet reaped), R/S otherwise; `-z` lists zombies only.
// footprint is `ri_phys_footprint`, the figure jetsam enforces; cpu% is over
// the sampling interval (0 on the first sample).
//
// Build: Scripts/stress/build-tools.sh, or by hand:
//   xcrun -sdk iphoneos clang -arch arm64 -O2 -o procstat procstat.c
//   ldid -Sprocstat.entitlements procstat
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <mach/mach_time.h>

int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

#define MAX_TRACKED 4096

static uint64_t lastCPU[MAX_TRACKED];
static pid_t lastPID[MAX_TRACKED];

static int matches(const char *name, int argc, char **names) {
    if (argc == 0) return 1;
    for (int i = 0; i < argc; i++) {
        if (strstr(name, names[i])) return 1;
    }
    return 0;
}

static void sample(int zombiesOnly, int nameCount, char **names, double interval, int first) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0)) { perror("sysctl"); exit(1); }
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = malloc(length);
    if (sysctl(mib, 3, processes, &length, NULL, 0)) { perror("sysctl"); exit(1); }
    int count = (int)(length / sizeof *processes);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    for (int i = 0; i < count; i++) {
        struct extern_proc *p = &processes[i].kp_proc;
        int zombie = p->p_stat == SZOMB;
        if (zombiesOnly && !zombie) continue;
        if (!matches(p->p_comm, nameCount, names)) continue;
        struct rusage_info_v4 usage;
        memset(&usage, 0, sizeof usage);
        int haveUsage = !zombie && proc_pid_rusage(p->p_pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0;
        uint64_t cpu = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom;
        double percent = 0;
        int slot = p->p_pid % MAX_TRACKED;
        if (!first && lastPID[slot] == p->p_pid && interval > 0) {
            percent = 100.0 * (double)(cpu - lastCPU[slot]) / (interval * 1e9);
        }
        lastPID[slot] = p->p_pid;
        lastCPU[slot] = cpu;
        printf("%d\t%d\t%c\t%llu\t%llu\t%.0f\t%s\n",
               p->p_pid, processes[i].kp_eproc.e_ppid,
               zombie ? 'Z' : (p->p_stat == SRUN ? 'R' : 'S'),
               haveUsage ? usage.ri_phys_footprint >> 10 : 0,
               haveUsage ? usage.ri_resident_size >> 10 : 0,
               percent, p->p_comm);
    }
    free(processes);
    fflush(stdout);
}

int main(int argc, char **argv) {
    int zombiesOnly = 0, samples = 1, option;
    double interval = 1;
    while ((option = getopt(argc, argv, "zn:c:")) != -1) {
        switch (option) {
        case 'z': zombiesOnly = 1; break;
        case 'n': interval = atof(optarg); break;
        case 'c': samples = atoi(optarg); break;
        default:
            fprintf(stderr, "usage: procstat [-z] [-n interval_s -c count] [name ...]\n");
            return 64;
        }
    }
    for (int i = 0; i < samples; i++) {
        if (samples > 1) printf("# sample %d\n", i);
        sample(zombiesOnly, argc - optind, argv + optind, interval, i == 0);
        if (i + 1 < samples) usleep((useconds_t)(interval * 1e6));
    }
    return 0;
}
