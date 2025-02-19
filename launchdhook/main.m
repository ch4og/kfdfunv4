#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <Foundation/Foundation.h>
#include <bsm/audit.h>
#include <xpc/xpc.h>
#include <stdio.h>
#include "fishhook.h"
#include <spawn.h>
#include <limits.h>
#include <dirent.h>
#include <stdbool.h>
#include <errno.h>
#include <signal.h>

#define PT_DETACH 11    /* stop tracing a process */
#define PT_ATTACHEXC 14 /* attach to running process with signal exception */
int ptrace(int request, pid_t pid, caddr_t addr, int data);

int posix_spawnattr_set_launch_type_np(posix_spawnattr_t *attr, uint8_t launch_type);

int (*orig_csops)(pid_t pid, unsigned int  ops, void * useraddr, size_t usersize);
int (*orig_csops_audittoken)(pid_t pid, unsigned int  ops, void * useraddr, size_t usersize, audit_token_t * token);
int (*orig_posix_spawn)(pid_t * __restrict pid, const char * __restrict path,
                        const posix_spawn_file_actions_t *file_actions,
                        const posix_spawnattr_t * __restrict attrp,
                        char *const argv[ __restrict], char *const envp[ __restrict]);

int (*orig_posix_spawnp)(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict file_actions, const posix_spawnattr_t *restrict attrp, char *const argv[restrict], char *const envp[restrict]);


int hooked_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    int result = orig_csops(pid, ops, useraddr, usersize);
    if (result != 0) return result;
    if (ops == 0) { // CS_OPS_STATUS
        *((uint32_t *)useraddr) |= 0x4000000; // CS_PLATFORM_BINARY
    }
    return result;
}

int hooked_csops_audittoken(pid_t pid, unsigned int ops, void * useraddr, size_t usersize, audit_token_t * token) {
    int result = orig_csops_audittoken(pid, ops, useraddr, usersize, token);
    if (result != 0) return result;
    if (ops == 0) { // CS_OPS_STATUS
        *((uint32_t *)useraddr) |= 0x4000000; // CS_PLATFORM_BINARY
    }
    return result;
}

void change_launchtype(const posix_spawnattr_t *attrp, const char *restrict path) {
    const char *prefixes[] = {
        "/private/var",
        "/var",
        "/private/preboot"
    };

    if (__builtin_available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)) {
        for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); ++i) {
            size_t prefix_len = strlen(prefixes[i]);
            if (strncmp(path, prefixes[i], prefix_len) == 0) {
                FILE *file = fopen("/var/mobile/mineek.log", "a");
                if (file && attrp != 0) {
                    char output[1024];
                    sprintf(output, "[mineek-launchd] setting launch type path %s to 0\n", path);
                    fputs(output, file);
                    fclose(file);
                }
                posix_spawnattr_set_launch_type_np((posix_spawnattr_t *)attrp, 0); // needs ios 16.0 sdk
                break;
            }
        }
    }
}

#define JB_ROOT_PREFIX ".jbroot-"
#define JB_RAND_LENGTH  (sizeof(uint64_t)*sizeof(char)*2)

int is_jbrand_value(uint64_t value)
{
   uint8_t check = value>>8 ^ value >> 16 ^ value>>24 ^ value>>32 ^ value>>40 ^ value>>48 ^ value>>56;
   return check == (uint8_t)value;
}

int is_jbroot_name(const char* name)
{
    if(strlen(name) != (sizeof(JB_ROOT_PREFIX)-1+JB_RAND_LENGTH))
        return 0;

    if(strncmp(name, JB_ROOT_PREFIX, sizeof(JB_ROOT_PREFIX)-1) != 0)
        return 0;

    char* endp=NULL;
    uint64_t value = strtoull(name+sizeof(JB_ROOT_PREFIX)-1, &endp, 16);
    if(!endp || *endp!='\0')
        return 0;

    if(!is_jbrand_value(value))
        return 0;

    return 1;
}

uint64_t resolve_jbrand_value(const char* name)
{
    if(strlen(name) != (sizeof(JB_ROOT_PREFIX)-1+JB_RAND_LENGTH))
        return 0;

    if(strncmp(name, JB_ROOT_PREFIX, sizeof(JB_ROOT_PREFIX)-1) != 0)
        return 0;

    char* endp=NULL;
    uint64_t value = strtoull(name+sizeof(JB_ROOT_PREFIX)-1, &endp, 16);
    if(!endp || *endp!='\0')
        return 0;

    if(!is_jbrand_value(value))
        return 0;

    return value;
}


NSString* find_jbroot()
{
    //jbroot path may change when re-randomize it
    NSString * jbroot = nil;
    NSArray *subItems = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application/" error:nil];
    for (NSString *subItem in subItems) {
        if (is_jbroot_name(subItem.UTF8String))
        {
            NSString* path = [@"/var/containers/Bundle/Application/" stringByAppendingPathComponent:subItem];
            jbroot = path;
            break;
        }
    }
    return jbroot;
}

NSString *jbroot(NSString *path)
{
    NSString* jbroot = find_jbroot();
    return [jbroot stringByAppendingPathComponent:path];
}

int hooked_posix_spawnp(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict file_actions, posix_spawnattr_t *attrp, char *const argv[restrict], char *const envp[restrict]) {
    change_launchtype(attrp, path);
    const char *springboardPath = "/System/Library/CoreServices/SpringBoard.app/SpringBoard";
    //const char *coolerSpringboard = "/var/jb/SpringBoard.app/SpringBoard";
    const char *coolerSpringboard = jbroot(@"/SpringBoard.app/SpringBoard").UTF8String;

    if (!strncmp(path, springboardPath, strlen(springboardPath))) {
        posix_spawnattr_set_launch_type_np((posix_spawnattr_t *)attrp, 0);
        FILE *file = fopen("/var/mobile/mineek.log", "a");
        char output[1024];
        sprintf(output, "[mineek-launchd] changing path %s to %s\n", path, coolerSpringboard);
        fputs(output, file);
        path = coolerSpringboard;
        fclose(file);
        return posix_spawnp(pid, path, file_actions, (posix_spawnattr_t *)attrp, argv, envp);
    }
            
    return orig_posix_spawnp(pid, path, file_actions, (posix_spawnattr_t *)attrp, argv, envp);
}

int hooked_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
    change_launchtype(attrp, path);
    // thanks htrowii and nathan!!
    const char *launchdPath = "/sbin/launchd";
    const char *coolerLaunchd = jbroot(@"launchdmineek").UTF8String;
    if (!strncmp(path, launchdPath, strlen(launchdPath))) {
        posix_spawnattr_set_launch_type_np((posix_spawnattr_t *)attrp, 0);
        path = coolerLaunchd;
        return posix_spawn(pid, path, file_actions, attrp, argv, envp);
    }
    return orig_posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

bool (*xpc_dictionary_get_bool_orig)(xpc_object_t dictionary, const char *key);
bool hook_xpc_dictionary_get_bool(xpc_object_t dictionary, const char *key) {
    if (!strcmp(key, "LogPerformanceStatistics")) return true;
    else return xpc_dictionary_get_bool_orig(dictionary, key);
}

__attribute__((constructor)) static void init(int argc, char **argv) {
    FILE *file;
    file = fopen("/var/mobile/mineek.log", "w");
    char output[1024];
    sprintf(output, "[mineek-launchd] launchdhook pid %d", getpid());
    printf("[mineek-launchd] launchdhook pid %d", getpid());
    fputs(output, file);
    fclose(file);
    sync();
    
    struct rebinding rebindings[] = (struct rebinding[]){
        {"csops", hooked_csops, (void *)&orig_csops},
        {"csops_audittoken", hooked_csops_audittoken, (void *)&orig_csops_audittoken},
        {"posix_spawn", hooked_posix_spawn, (void *)&orig_posix_spawn},
        {"posix_spawnp", hooked_posix_spawnp, (void *)&orig_posix_spawnp},
        {"xpc_dictionary_get_bool", hook_xpc_dictionary_get_bool, (void *)&xpc_dictionary_get_bool_orig},
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
}
