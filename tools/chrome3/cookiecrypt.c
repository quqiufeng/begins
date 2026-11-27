/* cookiecrypt.c —— 本机 Chrome/Chromium cookie 解密的 C 补充件（给 export_cookies.lua 用）
 *
 * 为什么需要 C：本机没装 libsecret 开发头文件（只有 .so.0），而 GNOME Keyring 的
 * 遍历（SecretService → collections → items）要靠 GObject 属性 + GList 指针走，
 * 在 LuaJIT FFI 里做既脆又长。这里把三件事封成两个函数：
 *   cc_password(labels)                    —— 按 label 从 keyring 取密码（Chrome Safe Storage）
 *   cc_unseal(pw, blob, len, host)         —— PBKDF2-SHA1(pw,"saltysalt",1,16) + AES-128-CBC 解密
 * 其余（SQLite 读表、host 过滤、Lua 表输出）都在 Lua 侧用 FFI 做。
 *
 * 编译（无任何头文件依赖，libsecret 原型手写）：
 *   cc -O2 -shared -fPIC -o libcookiecrypt.so cookiecrypt.c \
 *      -lsecret-1 -lgobject-2.0 -lglib-2.0 -lcrypto
 *
 * 与 python 版行为对齐的三处细节：
 *   1. 迭代次数 1（Linux；macOS 才是 1003），salt 固定 "saltysalt"。
 *   2. IV 固定 16 个空格。
 *   3. 新版 Chrome 明文前 32 字节 = sha256(host_key)，要剥掉（按 host 判据，不是按长度）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/evp.h>
#include <openssl/sha.h>

/* ---- 手写最小声明：本机 libsecret 无头文件 ---- */
typedef struct _GList { void *data; struct _GList *next; struct _GList *prev; } GList;
typedef struct _GError { unsigned int domain; int code; char *message; } GError;

extern void  g_object_get(void *obj, const char *first, ...);
extern void  g_object_unref(void *obj);

extern void  *secret_service_get_sync(int flags, void *cancellable, GError **err);
extern int    secret_service_load_collections_sync(void *svc, void *cancellable, GError **err);
extern int    secret_collection_load_items_sync(void *coll, void *cancellable, GError **err);
extern GList *secret_collection_get_items(void *coll);
extern const char *secret_item_get_label(void *item);
extern int    secret_item_load_secret_sync(void *item, void *cancellable, GError **err);
extern void  *secret_item_get_secret(void *item);
extern const char *secret_value_get(void *val, unsigned long *len);
extern void   secret_value_unref(void *val);

static int glist_len(GList *l) { int n = 0; while (l) { n++; l = l->next; } return n; }
static void *glist_nth(GList *l, int i) { while (l && i-- > 0) l = l->next; return l ? l->data : NULL; }

/* labels 是逗号分隔的候选名，命中任意一个即取 */
static int label_hit(const char *labels, const char *lab)
{
    size_t n = strlen(lab);
    const char *p = labels;
    while (p && *p) {
        const char *c = strchr(p, ',');
        size_t seg = c ? (size_t)(c - p) : strlen(p);
        if (seg == n && !strncmp(p, lab, n)) return 1;
        if (!c) break;
        p = c + 1;
    }
    return 0;
}

/* 从 keyring 取第 idx 个 label 匹配的密码：成功返回 malloc 的字符串，越界/失败 NULL
 * 为什么要 idx：keyring 里可能存在多条同名 "Chrome Safe Storage"（换过 profile / 留了旧条目），
 * 只有一把能解开当前 Cookies 库，所以调用方要逐把试，不能靠遍历顺序赌第一把。 */
char *cc_password_nth(const char *labels, int idx)
{
    GError *err = NULL;
    void *svc = secret_service_get_sync(0, NULL, &err);   /* 0：后面自己 load，不猜枚举值 */
    if (!svc) return NULL;

    secret_service_load_collections_sync(svc, NULL, &err);

    GList *colls = NULL;
    g_object_get(svc, "collections", &colls, NULL);

    char *out = NULL;
    int seen = 0;
    int nc = glist_len(colls);
    for (int i = 0; i < nc && !out; i++) {
        void *coll = glist_nth(colls, i);
        if (!coll) continue;
        secret_collection_load_items_sync(coll, NULL, &err);
        GList *items = secret_collection_get_items(coll);
        int ni = glist_len(items);
        for (int j = 0; j < ni && !out; j++) {
            void *it = glist_nth(items, j);
            if (!it) continue;
            const char *lab = secret_item_get_label(it);
            if (!lab || !label_hit(labels, lab)) continue;
            if (seen++ < idx) continue;
            if (secret_item_load_secret_sync(it, NULL, &err) != 1) continue;
            void *v = secret_item_get_secret(it);
            if (!v) continue;
            unsigned long len = 0;
            const char *s = secret_value_get(v, &len);
            if (s && len) {
                out = malloc(len + 1);
                if (out) { memcpy(out, s, len); out[len] = 0; }
            }
            secret_value_unref(v);
        }
    }
    g_object_unref(svc);
    return out;
}

/* UTF-8 合法性校验：python 版 decode() 失败即丢弃，这里等价 */
static int utf8_ok(const unsigned char *s, int n)
{
    int i = 0;
    while (i < n) {
        unsigned char c = s[i];
        int need; unsigned int cp;
        if (c < 0x80) { i++; continue; }
        else if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07; }
        else return 0;
        if (i + need > n - 1) return 0;          /* 截断的多字节序列 */
        for (int k = 1; k <= need; k++) {
            unsigned char cc = s[i + k];
            if ((cc & 0xC0) != 0x80) return 0;
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (need == 1 && cp < 0x80) return 0;
        if (need == 2 && cp < 0x800) return 0;
        if (need == 3 && cp < 0x10000) return 0;
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
        i += need + 1;
    }
    return 1;
}

/* 解密一条 encrypted_value：成功返回 malloc 的明文（UTF-8，无 sha256 前缀），失败 NULL */
char *cc_unseal(const char *password, const void *blob, int bloblen, const char *host)
{
    if (!password || !blob || bloblen < 4) return NULL;
    const unsigned char *b = blob;
    if (memcmp(b, "v10", 3) && memcmp(b, "v11", 3)) return NULL;

    int ctlen = bloblen - 3;
    if (ctlen <= 0 || (ctlen % 16)) return NULL;

    unsigned char key[16];
    if (!PKCS5_PBKDF2_HMAC_SHA1(password, (int)strlen(password),
                                (const unsigned char *)"saltysalt", 9, 1, 16, key))
        return NULL;

    unsigned char *buf = malloc((size_t)ctlen + 32);
    if (!buf) return NULL;

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int n1 = 0, n2 = 0, total = -1;
    if (ctx &&
        EVP_DecryptInit_ex(ctx, EVP_aes_128_cbc(), NULL, key,
                           (const unsigned char *)"                ") == 1 &&
        EVP_DecryptUpdate(ctx, buf, &n1, b + 3, ctlen) == 1 &&
        EVP_DecryptFinal_ex(ctx, buf + n1, &n2) == 1)
        total = n1 + n2;
    if (ctx) EVP_CIPHER_CTX_free(ctx);
    if (total < 0) { free(buf); return NULL; }

    /* 新版 Chrome：明文 = sha256(host_key) || 真实值（32 字节） */
    unsigned char h[SHA256_DIGEST_LENGTH];
    SHA256((const unsigned char *)host, strlen(host), h);
    int off = (total >= 32 && !memcmp(buf, h, 32)) ? 32 : 0;

    int vlen = total - off;
    char *res = NULL;
    if (vlen >= 0 && utf8_ok(buf + off, vlen)) {
        res = malloc((size_t)vlen + 1);
        if (res) { memcpy(res, buf + off, vlen); res[vlen] = 0; }
    }
    /* 明文擦一遍再还（内存里少留一份 cookie） */
    memset(buf, 0, (size_t)ctlen + 32);
    free(buf);
    return res;
}

/* 便捷入口：第一个匹配项（等价 cc_password_nth(labels, 0)） */
char *cc_password(const char *labels) { return cc_password_nth(labels, 0); }

void cc_free(void *p) { free(p); }
