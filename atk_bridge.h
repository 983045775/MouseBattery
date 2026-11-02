// atk_bridge.h — hidapi 的 Swift 桥接（隐藏 wchar_t 字段，只暴露需要的 API）
#ifndef ATK_BRIDGE_H
#define ATK_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct hid_device_;
typedef struct hid_device_ hid_device;

struct atk_hid_info {
    const char *path;
    unsigned short vendor_id;
    unsigned short product_id;
    unsigned short usage_page;
    unsigned short usage;
    int interface_number;
    struct atk_hid_info *next;
};

int  atk_hid_init(void);
int  atk_hid_exit(void);
struct atk_hid_info *atk_hid_enumerate(unsigned short vendor_id, unsigned short product_id);
void atk_hid_free_info(struct atk_hid_info *head);
hid_device *atk_hid_open_path(const char *path);
void atk_hid_close(hid_device *dev);
int  atk_hid_set_nonblocking(hid_device *dev, int nonblock);
int  atk_hid_send_feature_report(hid_device *dev, const unsigned char *data, size_t length);
int  atk_hid_read(hid_device *dev, unsigned char *data, size_t length);
int  atk_hid_read_timeout(hid_device *dev, unsigned char *data, size_t length, int milliseconds);
const char *atk_hid_error(hid_device *dev);

#ifdef __cplusplus
}
#endif

#endif
