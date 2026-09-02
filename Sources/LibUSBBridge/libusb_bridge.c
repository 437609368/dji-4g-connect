#include "libusb_bridge.h"

#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;

typedef struct {
    uint8_t length, descriptor_type;
    uint16_t usb_version;
    uint8_t device_class, device_subclass, device_protocol, max_packet_size;
    uint16_t vendor, product, device_version;
    uint8_t manufacturer, product_string, serial, configurations;
} usb_device_descriptor;

typedef struct {
    uint8_t length, descriptor_type, address, attributes;
    uint16_t max_packet_size;
    uint8_t interval, refresh, sync_address;
    const unsigned char *extra;
    int extra_length;
} usb_endpoint_descriptor;

typedef struct {
    uint8_t length, descriptor_type, interface_number, alternate_setting;
    uint8_t endpoints_count, interface_class, interface_subclass, interface_protocol, interface_string;
    const usb_endpoint_descriptor *endpoints;
    const unsigned char *extra;
    int extra_length;
} usb_interface_descriptor;

typedef struct {
    const usb_interface_descriptor *altsetting;
    int num_altsetting;
} usb_interface;

typedef struct {
    uint8_t length, descriptor_type;
    uint16_t total_length;
    uint8_t interfaces_count, configuration_value, configuration_string, attributes, max_power;
    const usb_interface *interfaces;
    const unsigned char *extra;
    int extra_length;
} usb_config_descriptor;

typedef int (*fn_init)(libusb_context **);
typedef void (*fn_exit)(libusb_context *);
typedef ssize_t (*fn_get_device_list)(libusb_context *, libusb_device ***);
typedef void (*fn_free_device_list)(libusb_device **, int);
typedef int (*fn_get_device_descriptor)(libusb_device *, usb_device_descriptor *);
typedef int (*fn_open)(libusb_device *, libusb_device_handle **);
typedef void (*fn_close)(libusb_device_handle *);
typedef int (*fn_get_config_descriptor)(libusb_device *, uint8_t, usb_config_descriptor **);
typedef void (*fn_free_config_descriptor)(usb_config_descriptor *);
typedef int (*fn_set_auto_detach)(libusb_device_handle *, int);
typedef int (*fn_claim_interface)(libusb_device_handle *, int);
typedef int (*fn_release_interface)(libusb_device_handle *, int);
typedef int (*fn_bulk_transfer)(libusb_device_handle *, unsigned char, unsigned char *, int, int *, unsigned int);

typedef struct {
    IOUSBInterfaceInterface **interface;
    int interface_number;
    UInt8 bulk_in_pipe;
    UInt8 bulk_out_pipe;
} iokit_at_port;

typedef struct {
    void *library;
    fn_init init;
    fn_exit exit;
    fn_get_device_list get_device_list;
    fn_free_device_list free_device_list;
    fn_get_device_descriptor get_device_descriptor;
    fn_open open;
    fn_close close;
    fn_get_config_descriptor get_config_descriptor;
    fn_free_config_descriptor free_config_descriptor;
    fn_set_auto_detach set_auto_detach;
    fn_claim_interface claim_interface;
    fn_release_interface release_interface;
    fn_bulk_transfer bulk_transfer;
} usb_api;

struct dji_usb_at {
    usb_api api;
    libusb_context *context;
    libusb_device_handle *handle;
    int interface_number;
    unsigned char endpoint_in;
    unsigned char endpoint_out;
    int claimed;
    iokit_at_port *iokit;
    char error[256];
};

static void set_error(char *error, size_t length, const char *message) {
    if (error && length) {
        snprintf(error, length, "%s", message);
    }
}

static void set_at_error(dji_usb_at *at, const char *message) {
    if (at) snprintf(at->error, sizeof(at->error), "%s", message);
}

const char *dji_usb_at_error(const dji_usb_at *at) {
    return at && at->error[0] ? at->error : "未知 USB AT 错误";
}

static int iokit_property_int(io_service_t service, const char *key, int fallback) {
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!name) return fallback;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, name, kCFAllocatorDefault, 0);
    CFRelease(name);
    if (!value) return fallback;
    int result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    }
    CFRelease(value);
    return result;
}

static void set_iokit_error(char *error, size_t length, const char *operation, IOReturn result) {
    char message[256];
    snprintf(message, sizeof(message), "%s 失败：0x%08x", operation, (unsigned)result);
    set_error(error, length, message);
}

static IOUSBInterfaceInterface **iokit_create_interface(io_service_t service, char *error, size_t error_length) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(
        service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (result != kIOReturnSuccess || !plugin) {
        set_iokit_error(error, error_length, "创建 USB AT 接口", result);
        return NULL;
    }
    IOUSBInterfaceInterface **interface = NULL;
    HRESULT query = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&interface);
    (*plugin)->Release(plugin);
    if (query != 0 || !interface) {
        set_error(error, error_length, "获取 USB AT 接口对象失败");
        return NULL;
    }
    return interface;
}

static int iokit_discover_pipes(IOUSBInterfaceInterface **interface, UInt8 *bulk_in, UInt8 *bulk_out) {
    UInt8 count = 0;
    if ((*interface)->GetNumEndpoints(interface, &count) != kIOReturnSuccess) return -1;
    *bulk_in = 0;
    *bulk_out = 0;
    for (UInt8 pipe = 1; pipe <= count; pipe++) {
        UInt8 direction = 0, number = 0, type = 0, interval = 0;
        UInt16 packet = 0;
        if ((*interface)->GetPipeProperties(interface, pipe, &direction, &number, &type, &packet, &interval) != kIOReturnSuccess) continue;
        if (type != kUSBBulk) continue;
        if (direction == kUSBIn) *bulk_in = pipe;
        if (direction == kUSBOut) *bulk_out = pipe;
    }
    return *bulk_in && *bulk_out ? 0 : -1;
}

static void iokit_close_port(iokit_at_port *port) {
    if (!port) return;
    if (port->interface) {
        (*port->interface)->USBInterfaceClose(port->interface);
        (*port->interface)->Release(port->interface);
    }
    free(port);
}

static int iokit_write(iokit_at_port *port, const unsigned char *data, size_t length, unsigned int timeout_ms) {
    if (!port || !port->interface) return -1;
    return (*port->interface)->WritePipeTO(port->interface, port->bulk_out_pipe,
        (void *)data, (UInt32)length, timeout_ms, timeout_ms) == kIOReturnSuccess ? 0 : -1;
}

static int iokit_read(iokit_at_port *port, unsigned char *data, size_t capacity, int *received, unsigned int timeout_ms) {
    if (!port || !port->interface || !received) return -1;
    UInt32 length = (UInt32)capacity;
    IOReturn result = (*port->interface)->ReadPipeTO(port->interface, port->bulk_in_pipe,
        data, &length, timeout_ms, timeout_ms);
    if (result != kIOReturnSuccess) return -2;
    *received = (int)length;
    return 0;
}

static int iokit_probe(iokit_at_port *port) {
    static const unsigned char command[] = "AT\r";
    if (iokit_write(port, command, sizeof(command) - 1, 1000) != 0) return -1;
    unsigned char response[256];
    size_t used = 0;
    for (int attempt = 0; attempt < 8; attempt++) {
        int received = 0;
        int result = iokit_read(port, response + used, sizeof(response) - used - 1, &received, 150);
        if (result != 0) continue;
        used += (size_t)received;
        response[used] = '\0';
        if (strstr((char *)response, "OK")) return 0;
        if (used >= sizeof(response) - 1) break;
    }
    return -1;
}

static int try_iokit_open(dji_usb_at *at, char *error, size_t error_length) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostInterface");
    if (!matching) return -1;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != kIOReturnSuccess) return -1;

    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        int vid = iokit_property_int(service, "idVendor", -1);
        int pid = iokit_property_int(service, "idProduct", -1);
        int ifnum = iokit_property_int(service, "bInterfaceNumber", -1);
        int cls = iokit_property_int(service, "bInterfaceClass", -1);
        int subclass = iokit_property_int(service, "bInterfaceSubClass", -1);
        int protocol = iokit_property_int(service, "bInterfaceProtocol", -1);
        int endpoints = iokit_property_int(service, "bNumEndpoints", -1);
        if (vid != 0x2c7c && vid != 0x2ca3) { IOObjectRelease(service); continue; }
        if ((vid == 0x2c7c && pid != 0x0125) || (vid == 0x2ca3 && pid != 0x4006)) { IOObjectRelease(service); continue; }
        // QDC507's AT pair is 2/3 in the vendor, ECM and MBIM layouts.
        // In RNDIS it moves to 4/5. Interfaces 0/1 are non-AT vendor control
        // functions and can acknowledge a write without being an AT channel.
        if (cls != 0xff || subclass != 0x00 || protocol != 0x00 || endpoints < 2 || ifnum < 2) {
            IOObjectRelease(service);
            continue;
        }

        IOUSBInterfaceInterface **interface = iokit_create_interface(service, error, error_length);
        IOObjectRelease(service);
        if (!interface) continue;
        IOReturn open_result = (*interface)->USBInterfaceOpen(interface);
        if (open_result != kIOReturnSuccess) {
            set_iokit_error(error, error_length, "打开 USB AT 接口", open_result);
            (*interface)->Release(interface);
            continue;
        }
        iokit_at_port *port = calloc(1, sizeof(*port));
        if (!port || iokit_discover_pipes(interface, &port->bulk_in_pipe, &port->bulk_out_pipe) != 0) {
            set_error(error, error_length, "AT 接口没有可用的 bulk IN/OUT 管道");
            free(port);
            (*interface)->USBInterfaceClose(interface);
            (*interface)->Release(interface);
            continue;
        }
        port->interface = interface;
        port->interface_number = ifnum;
        if (iokit_probe(port) == 0) {
            at->iokit = port;
            set_at_error(at, "");
            IOObjectRelease(iterator);
            return 0;
        }
        iokit_close_port(port);
    }
    IOObjectRelease(iterator);
    return -1;
}

static int load_symbol(void *library, void **destination, const char *name) {
    *destination = dlsym(library, name);
    return *destination != NULL;
}

static int load_api(usb_api *api, char *error, size_t error_length) {
    memset(api, 0, sizeof(*api));
    api->library = dlopen("@rpath/libusb-1.0.0.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!api->library) api->library = dlopen("libusb-1.0.0.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!api->library) {
        set_error(error, error_length, "未找到内置 libusb");
        return -1;
    }

#define LOAD(name) if (!load_symbol(api->library, (void **)&api->name, "libusb_" #name)) { set_error(error, error_length, "libusb 接口不完整"); dlclose(api->library); return -1; }
    LOAD(init); LOAD(exit); LOAD(get_device_list); LOAD(free_device_list);
    LOAD(get_device_descriptor); LOAD(open); LOAD(close); LOAD(get_config_descriptor);
    LOAD(free_config_descriptor); LOAD(claim_interface); LOAD(release_interface); LOAD(bulk_transfer);
    load_symbol(api->library, (void **)&api->set_auto_detach, "libusb_set_auto_detach_kernel_driver");
#undef LOAD
    return 0;
}

static int wait_for_response(dji_usb_at *at, char *response, size_t response_length, unsigned int timeout_ms, int stop_at_prompt) {
    size_t used = 0;
    unsigned int elapsed = 0;
    response[0] = '\0';
    while (elapsed < timeout_ms && used + 1 < response_length) {
        unsigned char buffer[512];
        int received = 0;
        int result;
        if (at->iokit) {
            result = iokit_read(at->iokit, buffer, sizeof(buffer), &received, 150);
            if (result == -2) result = -7;
        } else {
            result = at->api.bulk_transfer(at->handle, at->endpoint_in, buffer, (int)sizeof(buffer), &received, 150);
        }
        elapsed += 150;
        if (result != 0 || received <= 0) continue;
        size_t copy = (size_t)received;
        if (copy > response_length - used - 1) copy = response_length - used - 1;
        memcpy(response + used, buffer, copy);
        used += copy;
        response[used] = '\0';
        if (stop_at_prompt && strchr(response, '>')) return 0;
        if (strstr(response, "OK") || strstr(response, "ERROR") || strstr(response, "NO CARRIER")) return 0;
    }
    return 0;
}

static int write_command(dji_usb_at *at, const char *command) {
    unsigned char buffer[1024];
    int length = snprintf((char *)buffer, sizeof(buffer), "%s\r", command);
    if (length <= 0 || length >= (int)sizeof(buffer)) return -1;
    if (at->iokit) {
        if (iokit_write(at->iokit, buffer, (size_t)length, 1500) != 0) {
            char message[256];
            snprintf(message, sizeof(message), "IOKit 写入 AT 接口失败（interface %d，out pipe %u）",
                     at->iokit->interface_number, at->iokit->bulk_out_pipe);
            set_at_error(at, message);
            return -1;
        }
        return 0;
    }
    int written = 0;
    return at->api.bulk_transfer(at->handle, at->endpoint_out, buffer, length, &written, 1500) == 0 && written == length ? 0 : -1;
}

dji_usb_at *dji_usb_at_create(void) {
    return calloc(1, sizeof(dji_usb_at));
}

int dji_usb_at_open(dji_usb_at *at, char *error, size_t error_length) {
    if (!at) return -1;
    if (try_iokit_open(at, error, error_length) == 0) return 0;
    if (load_api(&at->api, error, error_length) != 0) return -1;
    int result = at->api.init(&at->context);
    if (result != 0) { set_error(error, error_length, "libusb 初始化失败"); return -1; }

    libusb_device **devices = NULL;
    ssize_t count = at->api.get_device_list(at->context, &devices);
    if (count < 0) { set_error(error, error_length, "无法枚举 USB 设备"); return -1; }

    for (ssize_t i = 0; i < count && !at->handle; i++) {
        usb_device_descriptor descriptor;
        if (at->api.get_device_descriptor(devices[i], &descriptor) != 0) continue;
        int matching = (descriptor.vendor == 0x2c7c && descriptor.product == 0x0125) ||
                       (descriptor.vendor == 0x2ca3 && descriptor.product == 0x4006);
        if (!matching || at->api.open(devices[i], &at->handle) != 0) continue;

        usb_config_descriptor *configuration = NULL;
        if (at->api.get_config_descriptor(devices[i], 0, &configuration) != 0) { at->api.close(at->handle); at->handle = NULL; continue; }
        for (int interface_index = 0; interface_index < configuration->interfaces_count && !at->claimed; interface_index++) {
            const usb_interface *interface = &configuration->interfaces[interface_index];
            for (int alt = 0; alt < interface->num_altsetting && !at->claimed; alt++) {
                const usb_interface_descriptor *setting = &interface->altsetting[alt];
                unsigned char endpoint_in = 0, endpoint_out = 0;
                for (int endpoint = 0; endpoint < setting->endpoints_count; endpoint++) {
                    const usb_endpoint_descriptor *candidate = &setting->endpoints[endpoint];
                    if ((candidate->attributes & 0x03) != 0x02) continue;
                    if (candidate->address & 0x80) endpoint_in = candidate->address;
                    else endpoint_out = candidate->address;
                }
                if (!endpoint_in || !endpoint_out) continue;
                if (at->api.set_auto_detach) at->api.set_auto_detach(at->handle, 1);
                if (at->api.claim_interface(at->handle, setting->interface_number) != 0) continue;
                at->interface_number = setting->interface_number;
                at->endpoint_in = endpoint_in;
                at->endpoint_out = endpoint_out;
                at->claimed = 1;
                if (write_command(at, "AT") != 0) { at->api.release_interface(at->handle, at->interface_number); at->claimed = 0; continue; }
                char response[256];
                wait_for_response(at, response, sizeof(response), 1000, 0);
                if (!strstr(response, "OK")) { at->api.release_interface(at->handle, at->interface_number); at->claimed = 0; }
            }
        }
        at->api.free_config_descriptor(configuration);
        if (!at->claimed) { at->api.close(at->handle); at->handle = NULL; }
    }
    at->api.free_device_list(devices, 1);
    if (!at->claimed) { set_error(error, error_length, "未找到可用的 USB AT 接口"); return -1; }
    return 0;
}

int dji_usb_at_command(dji_usb_at *at, const char *command, char *response, size_t response_length, unsigned int timeout_ms) {
    if (!at || (!at->claimed && !at->iokit) || !command || !response) return -1;
    if (write_command(at, command) != 0) return -1;
    return wait_for_response(at, response, response_length, timeout_ms, 0);
}

int dji_usb_at_send_sms(dji_usb_at *at, const char *recipient_ucs2, const char *body_ucs2, char *response, size_t response_length) {
    if (!at || (!at->claimed && !at->iokit) || !recipient_ucs2 || !body_ucs2 || !response) return -1;
    if (dji_usb_at_command(at, "AT+CMGF=1", response, response_length, 1500) != 0) return -1;
    if (dji_usb_at_command(at, "AT+CSCS=\"UCS2\"", response, response_length, 1500) != 0) return -1;
    char command[1200];
    snprintf(command, sizeof(command), "AT+CMGS=\"%s\"", recipient_ucs2);
    if (write_command(at, command) != 0) return -1;
    if (wait_for_response(at, response, response_length, 2500, 1) != 0 || !strchr(response, '>')) return -1;
    unsigned char *payload = malloc(strlen(body_ucs2) + 2);
    if (!payload) return -1;
    size_t length = strlen(body_ucs2);
    memcpy(payload, body_ucs2, length);
    payload[length] = 26;
    int result;
    int written = 0;
    if (at->iokit) {
        result = iokit_write(at->iokit, payload, length + 1, 1500);
        written = result == 0 ? (int)length + 1 : 0;
    } else {
        result = at->api.bulk_transfer(at->handle, at->endpoint_out, payload, (int)length + 1, &written, 1500);
    }
    free(payload);
    if (result != 0 || written != (int)length + 1) return -1;
    return wait_for_response(at, response, response_length, 10000, 0);
}

void dji_usb_at_close(dji_usb_at *at) {
    if (!at) return;
    if (at->iokit) {
        iokit_close_port(at->iokit);
        at->iokit = NULL;
    }
    if (at->claimed && at->handle) at->api.release_interface(at->handle, at->interface_number);
    at->claimed = 0;
    if (at->handle) at->api.close(at->handle);
    at->handle = NULL;
    if (at->context) at->api.exit(at->context);
    at->context = NULL;
    if (at->api.library) dlclose(at->api.library);
    memset(&at->api, 0, sizeof(at->api));
}

void dji_usb_at_destroy(dji_usb_at *at) {
    if (!at) return;
    dji_usb_at_close(at);
    free(at);
}
