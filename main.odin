#+vet
package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:log"
import "core:fmt"
import "core:sys/posix"
import "core:thread"
import "base:runtime"

HID_DEVICE_PATH := os.args[1]

exit: bool

Macro_Action_Data :: struct {
    assigned_action: string,
    allocator: runtime.Allocator,
}

macro_action :: proc(t: ^thread.Thread) {
    d := (^Macro_Action_Data)(t.data)

    context.allocator = d.allocator

    command := os.Process_Desc {
        command = {"sh", "-c", d.assigned_action },
    }

    _, process_err := os.process_start(command)

    if process_err != nil {
        log.errorf("failed action for %v: %v", d.assigned_action, process_err)
    }

    free_all(d.allocator)
}

main :: proc() {
    context.logger = log.create_console_logger(.Info, {.Level, .Date, .Time})

    if len(os.args) <= 1 {
        log.fatalf("first argument must be HID device path")
        os.exit(1)
    }

    user_config_dir, user_config_dir_err := os.user_config_dir(context.temp_allocator)
    if user_config_dir_err != nil {
        log.errorf("failed retrieving configuration directory")
        return
    }

    config_file_path := fmt.tprint(user_config_dir, "/macropad/config.json", sep = "")
    config_file, config_file_err := os.read_entire_file(config_file_path, context.allocator)

    if config_file_err != nil {
        fmt.println("fuck me")
    }

    config_map, config_map_err := json.parse(config_file)

    if config_map_err != nil {
        log.errorf("failed parsing config file: %v", config_map_err) 
        return
    }

    hid, hid_err := os.open(HID_DEVICE_PATH, {.Read})

    if hid_err != nil {
        log.errorf("failed opening hid device at %v: %s", HID_DEVICE_PATH, hid_err)
        os.exit(1)
    }

    defer os.close(hid)

    log.info("opened HID device stream")

    buf := make([dynamic]u8, 2, 2)

    sa: posix.sigaction_t

    sa.sa_handler = proc "c" (sig: posix.Signal) {
        exit = true
    }
    posix.sigaction(.SIGINT, &sa, nil)
    posix.sigaction(.SIGTERM, &sa, nil)

    log.info("begin reading device data")

    threads := make([dynamic]^thread.Thread)
    
    for !exit {
        _, hid_read_err := os.read(hid, buf[:])

        switch hid_read_err {
        // NOTE(andrei): EIO here means device lost connection
        case .EIO:
            log.errorf("failed receiving data from %v: %v", HID_DEVICE_PATH, hid_read_err)
            exit = true
        }

        hid_key := fmt.tprintf("%v.%v", buf[0], buf[1])
        assigned_action := config_map.(json.Object)[hid_key].(json.String)

        t := thread.create(macro_action)

        thread_allocator := runtime.default_allocator()
        data := new(Macro_Action_Data, thread_allocator)

        data.allocator = thread_allocator
        data.assigned_action = strings.clone(assigned_action, data.allocator)

        t.data = data

        log.infof("playing macro %v [%v]", hid_key, assigned_action)
        thread.start(t)

        append(&threads, t)

        free_all(context.temp_allocator)
    }

    // Wait for all threads to finish before exiting.
    for t in threads {
        thread.join(t)

        thread.destroy(t)
    }

    log.info("shutting down")
}
