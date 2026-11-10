#include <stdio.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/utsname.h>
#include <linux/reboot.h>
#include <fcntl.h>
#include <string.h>

static void cat(const char *p){
    int fd=open(p,O_RDONLY); if(fd<0){printf("  [读不到 %s]\n",p);return;}
    char b[4096]; int n; while((n=read(fd,b,sizeof b-1))>0){b[n]=0;printf("%s",b);} close(fd);
}
int main(void){
    mount("proc","/proc","proc",0,0);
    mount("sysfs","/sys","sysfs",0,0);
    mount("devtmpfs","/dev","devtmpfs",0,0);
    printf("\n========== LITE-INIT 用户态已启动 ==========\n");
    struct utsname u; if(!uname(&u))
        printf("[OK] uname: %s %s %s\n",u.sysname,u.release,u.version);
    printf("[OK] /proc/version: "); cat("/proc/version");
    printf("[OK] /proc/cpuinfo: "); { int fd=open("/proc/cpuinfo",O_RDONLY); char b[256]; int n=read(fd,b,250); if(n>0){b[n]=0; printf("%s", b);} close(fd);}
    printf("[OK] 内存: "); cat("/proc/meminfo");
    printf("[OK] 已加载模块数: "); { int fd=open("/proc/modules",O_RDONLY); char b[1]; int n=read(fd,b,1); printf(n>0?"有\n":"无（未加载任何 .ko，正常）\n"); close(fd);}
    printf("\n========== INIT: 引导完成，正常关机 ==========\n");
    fflush(stdout); sync(); sleep(1);
    reboot(LINUX_REBOOT_CMD_POWER_OFF);
    return 0;
}
