"""Compile actual firmware admission/timer/disconnect functions with offline BLE stubs."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys
import tempfile

root, output = Path(sys.argv[1]), Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
source_path = root / "firmware/main/main.c"
source = source_path.read_text()

def member(name):
    match = re.search(r"static [^\n]+ " + name + r"\([^\n]*\) \{", source)
    assert match, name
    i, depth = match.end(), 1
    while depth:
        depth += (source[i] == "{") - (source[i] == "}")
        i += 1
    return source[match.start():i]

head = r'''
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#define BLE_HS_CONN_HANDLE_NONE 65535
#define MAX_LINKS 2
#define AGENT_LED_IDLE 0
#define BLE_HS_ENOTCONN 10
#define BLE_HS_ENOMEM 11
#define BLE_ATT_ERR_UNLIKELY 12
#define BLE_ATT_ERR_INSUFFICIENT_ENC 13
#define BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN 14
#define BLE_ATT_ERR_INSUFFICIENT_RES 15
#define BLE_GAP_EVENT_ENC_CHANGE 1
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define OS_MBUF_PKTLEN(om) ((om)->len)
struct ble_npl_callout { bool armed; unsigned ms; };
struct ble_npl_event { int unused; };
struct os_mbuf { uint8_t data[32]; unsigned len; };
struct ble_gatt_access_ctxt { struct os_mbuf *om; };
struct ble_gap_conn_desc { struct { bool encrypted; } sec_state; };
struct ble_gap_event { int type; struct { uint16_t conn_handle; int status; } enc_change; };
static bool encrypted_links[3];
static unsigned report_count, down_count, release_count, failed_notifications;
static int ble_gap_conn_find(uint16_t conn, struct ble_gap_conn_desc *desc) {
    desc->sec_state.encrypted = conn < 3 && encrypted_links[conn]; return 0;
}
static int ble_npl_callout_stop(struct ble_npl_callout *timer) { timer->armed = false; return 0; }
static uint32_t ble_npl_time_ms_to_ticks32(uint32_t ms) { return ms; }
static int ble_npl_callout_reset(struct ble_npl_callout *timer, uint32_t ms) { timer->armed = true; timer->ms = ms; return 0; }
static struct os_mbuf *ble_hs_mbuf_from_flat(const void *data, unsigned len) {
    static struct os_mbuf om; memcpy(om.data, data, len); om.len = len; return &om;
}
static int ble_gatts_notify_custom(uint16_t conn, uint16_t attr, struct os_mbuf *om) {
    (void)conn; (void)attr;
    if (failed_notifications) { failed_notifications--; return BLE_HS_ENOMEM; }
    report_count++; if (om->data[0]) down_count++; else release_count++;
    return 0;
}
static int ble_hs_mbuf_to_flat(struct os_mbuf *om, void *data, unsigned size, uint16_t *len) {
    assert(om->len <= size); memcpy(data, om->data, om->len); *len = om->len; return 0;
}
static void status_led_set_connected(bool connected) { (void)connected; }
static void status_led_set_task(int status) { (void)status; }
static void notify_status(void) { }
static int release_keyboard(void) { return 0; }
static int send_keyboard(uint8_t modifier, uint8_t key) { (void)modifier; (void)key; return 0; }
static void status_bytes(uint8_t value[8]) { memset(value, 0, 8); }
static int append(struct ble_gatt_access_ctxt *ctxt, const void *data, size_t len) { (void)ctxt; (void)data; (void)len; return 0; }
static int move_access(uint16_t conn, struct ble_gatt_access_ctxt *ctxt) { (void)conn; (void)ctxt; assert(!"move path outside this click regression"); return -1; }
'''
constants = "\n".join(re.findall(r"^#define (?:PACKET_SIZE|MOVE_PACKET_SIZE|WATCHDOG_MS) .+$", source, re.M))
globals_source = source[source.index("static uint16_t links["):source.index("void ble_store_config_init(void);")]
errors = re.search(r"enum \{ ERR_NONE[^\n]+", source).group()
functions = ["link_count", "link_exists", "remember_link", "forget_link", "encrypted", "subscribed", "ready", "keyboard_ready", "reset_timer", "send_report", "cancel_click", "cancel_move", "watchdog_event", "click_event", "reject", "control_access", "clear_link"]
encryption_case = source[source.index("    case BLE_GAP_EVENT_ENC_CHANGE:"):source.index("    case BLE_GAP_EVENT_SUBSCRIBE:")]
encryption_wrapper = "static int encryption_event(struct ble_gap_event *event) { switch(event->type) {\n" + encryption_case + "default: return -1; } }\n"
main = r'''
static void setup(void) {
    links[0] = 1; links[1] = 2; control_connection = 1; hid_connection = 2;
    keyboard_connection = BLE_HS_CONN_HANDLE_NONE;
    encrypted_links[1] = encrypted_links[2] = true;
    report_subscribed = true; boot_subscribed = false; suspended = false; protocol_mode = 1;
    memset(current_report, 0, sizeof(current_report));
    report_count = down_count = release_count = failed_notifications = 0;
    pending_move = false; cancel_click(); ble_npl_callout_stop(&watchdog_timer);
}
static void queue(void) {
    struct os_mbuf packet = {.data = {1, 2, 1, 0, 1, 0, 0, 0, 100, 0}, .len = PACKET_SIZE};
    struct ble_gatt_access_ctxt context = {.om = &packet};
    assert(control_access(1, 0, &context, NULL) == 0);
    assert(pending_click && click_owner == 1 && click_timer.armed && click_timer.ms == 100 && down_count == 0);
}
int main(void) {
    unsigned cases = 0;
    setup(); queue(); clear_link(1); click_event(NULL);
    assert(!pending_click && !click_timer.armed && down_count == 0 && ready()); cases++;
    // Handle reuse must not resurrect the old queued timer.
    assert(remember_link(1)); click_event(NULL); assert(down_count == 0); cases++;
    // A status read can change control_connection without owning this click.
    setup(); queue(); struct ble_gatt_access_ctxt status = {0};
    assert(control_access(2, 0, &status, (void *)1) == 0 && control_connection == 2);
    clear_link(1); click_event(NULL); assert(!pending_click && down_count == 0); cases++;
    setup(); queue(); clear_link(2); click_event(NULL);
    assert(!pending_click && down_count == 0 && !ready()); cases++;
    setup(); queue(); clear_link(3); click_event(NULL); click_event(NULL);
    assert(down_count == 1 && release_count == 1 && !pending_click && current_report[0] == 0); cases++;
    setup(); queue(); click_event(NULL); assert(click_pressed && current_report[0] == 1);
    clear_link(1); click_event(NULL); assert(down_count == 1 && release_count == 1 && current_report[0] == 0); cases++;
    setup(); queue(); click_event(NULL); failed_notifications = 1;
    clear_link(1); assert(!pending_click && current_report[0] == 1 && watchdog_timer.armed && watchdog_timer.ms == 50);
    watchdog_event(NULL); assert(down_count == 1 && release_count == 1 && current_report[0] == 0); cases++;
    setup(); queue(); encrypted_links[1] = false; click_event(NULL);
    assert(!pending_click && down_count == 0 && last_error == ERR_NOT_READY); cases++;
    setup(); queue(); forget_link(1); click_event(NULL);
    assert(!pending_click && down_count == 0 && last_error == ERR_NOT_READY); cases++;
    setup(); queue(); encrypted_links[1] = false;
    struct ble_gap_event event = {.type = BLE_GAP_EVENT_ENC_CHANGE, .enc_change = {.conn_handle = 1}};
    assert(encryption_event(&event) == 0); click_event(NULL); assert(!pending_click && down_count == 0); cases++;
    setup(); queue(); click_event(NULL); encrypted_links[1] = false; failed_notifications = 1; click_event(NULL);
    assert(!pending_click && current_report[0] == 1 && watchdog_timer.armed);
    watchdog_event(NULL); assert(current_report[0] == 0 && down_count == 1 && release_count == 1); cases++;
    setup(); queue(); click_event(NULL); failed_notifications = 1; click_event(NULL);
    assert(pending_click && click_pressed && click_timer.armed && current_report[0] == 1);
    click_event(NULL); assert(!pending_click && down_count == 1 && release_count == 1); cases++;
    printf("{\"passedCases\":%u,\"realDeviceOrNetwork\":false}\n", cases);
}
'''
code = head + constants + "\n" + globals_source + errors + "\n" + "\n".join(map(member, functions)) + encryption_wrapper + main
probe = output / "firmware-click-check.c"
probe.write_text(code)
with tempfile.TemporaryDirectory(prefix="firmware-click-check-") as temp:
    binary = Path(temp) / "checks"
    compile_result = subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-variable", str(probe), "-o", str(binary)], capture_output=True, text=True)
    (output / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
    assert compile_result.returncode == 0, compile_result.stderr
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    (output / "run.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stderr
    assert source_path.read_text() == source, "Firmware changed during verification"
    report = json.loads(result.stdout)
    report.update(source=str(source_path), sourceSHA256=hashlib.sha256(source.encode()).hexdigest(), extractedUnmodifiedFunctions=functions,
                  otherActualCode=["global declarations", "encryption-change switch branch"],
                  syntheticBoundaries=["BLE link encryption and transport", "callout timer scheduling", "LED/status/keyboard/move stubs"])
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Firmware click ownership: {report['passedCases']} offline cases passed; evidence: {output}")
