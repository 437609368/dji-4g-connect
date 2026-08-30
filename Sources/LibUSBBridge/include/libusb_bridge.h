#ifndef LIBUSB_BRIDGE_H
#define LIBUSB_BRIDGE_H

#include <stddef.h>

typedef struct dji_usb_at dji_usb_at;

dji_usb_at *dji_usb_at_create(void);
int dji_usb_at_open(dji_usb_at *at, char *error, size_t error_length);
const char *dji_usb_at_error(const dji_usb_at *at);
int dji_usb_at_command(dji_usb_at *at, const char *command, char *response, size_t response_length, unsigned int timeout_ms);
int dji_usb_at_send_sms(dji_usb_at *at, const char *recipient_ucs2, const char *body_ucs2, char *response, size_t response_length);
void dji_usb_at_close(dji_usb_at *at);
void dji_usb_at_destroy(dji_usb_at *at);

#endif
