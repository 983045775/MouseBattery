// atk_bridge.c — hidapi 的薄封装（把 hid_device_info 转换成不含 wchar_t 的结构）
#include "atk_bridge.h"
#include "hidapi.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int atk_hid_init(void) { return hid_init(); }
int atk_hid_exit(void) { return hid_exit(); }

struct atk_hid_info *atk_hid_enumerate(unsigned short vendor_id, unsigned short product_id)
{
    struct hid_device_info *head = hid_enumerate(vendor_id, product_id);
    if (!head) return NULL;

    struct atk_hid_info *h = NULL, *t = NULL;
    struct hid_device_info *e;
    for (e = head; e; e = e->next) {
        struct atk_hid_info *n = (struct atk_hid_info *)calloc(1, sizeof(*n));
        size_t pl;
        if (!n) break;
        pl = strlen(e->path) + 1;
        n->path = (const char *)malloc(pl);
        if (!n->path) { free(n); break; }
        memcpy((void *)n->path, e->path, pl);
        n->vendor_id = e->vendor_id;
        n->product_id = e->product_id;
        n->usage_page = e->usage_page;
        n->usage = e->usage;
        n->interface_number = e->interface_number;
        if (t) t->next = n; else h = n;
        t = n;
    }
    hid_free_enumeration(head);
    return h;
}

void atk_hid_free_info(struct atk_hid_info *head)
{
    while (head) {
        struct atk_hid_info *n = head->next;
        free((void *)head->path);
        free(head);
        head = n;
    }
}

hid_device *atk_hid_open_path(const char *path) { return hid_open_path(path); }
void atk_hid_close(hid_device *dev) { if (dev) hid_close(dev); }
int atk_hid_set_nonblocking(hid_device *dev, int nonblock) { return hid_set_nonblocking(dev, nonblock); }
int atk_hid_send_feature_report(hid_device *dev, const unsigned char *data, size_t length) { return hid_send_feature_report(dev, data, length); }
int atk_hid_read(hid_device *dev, unsigned char *data, size_t length) { return hid_read(dev, data, length); }
int atk_hid_read_timeout(hid_device *dev, unsigned char *data, size_t length, int milliseconds) { return hid_read_timeout(dev, data, length, milliseconds); }
const char *atk_hid_error(hid_device *dev)
{
    static char buf[256];
    const wchar_t *e = hid_error(dev);
    size_t n = 0, i, o = 0;
    if (!e) return "";
    while (e[n] && n < 64) n++;
    /* macOS wchar_t 是 UTF-32，转成 UTF-8 */
    for (i = 0; i < n && o + 4 < sizeof(buf); i++) {
        uint32_t cp = (uint32_t)e[i];
        if (cp < 0x80) {
            buf[o++] = (char)cp;
        } else if (cp < 0x800) {
            buf[o++] = (char)(0xC0 | (cp >> 6));
            buf[o++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            buf[o++] = (char)(0xE0 | (cp >> 12));
            buf[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            buf[o++] = (char)(0x80 | (cp & 0x3F));
        } else {
            buf[o++] = (char)(0xF0 | (cp >> 18));
            buf[o++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            buf[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            buf[o++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    buf[o] = '\0';
    return buf;
}
