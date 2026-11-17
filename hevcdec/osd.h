/* osd.h —— 屏幕提示（音量/暂停/位置）的唯一入口
 *
 * 只存"现在该显示什么"，不碰任何后端。谁来画是 Renderer 的事：
 *   gl  —— glout.c 每帧把它合成到画面底部（含暂停时的补画 repaint）
 *   drm —— 没有叠加层（NV12 直挂 plane），收到文本只是记住，屏幕上没有
 *
 * 线程：pctl 线程写（按键），播放线程读（出帧），内部加锁。
 */
#ifndef OSD_H
#define OSD_H

/* 显示 dur 秒（自动消失）。dur<=0 表示一直显示到下一次 osd_show/osd_clear */
void osd_show(double dur, const char *fmt, ...);
void osd_clear(void);

int osd_active(void);		/* 现在还有东西要显示吗 */
unsigned osd_gen(void);		/* 内容版本号：变了就得重传纹理 */
int osd_poll_dirty(void);	/* 1 = 屏幕需要重画一次（出现/到期各一次） */

/* 把当前文本烘成 RGBA8（含半透明底条），返回 malloc 的缓冲，调用方 free。
 * 没内容时返回 NULL。 */
unsigned char *osd_rgba(int *w, int *h);

#endif /* OSD_H */
