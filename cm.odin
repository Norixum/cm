package cm

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"
import "core:strconv"
import "core:sys/linux"

foreign import libc "system:c"

foreign libc {
    environ: [^]cstring
}

Error :: struct {
    line_idx: int,
    file_name: string,
    line_number: int,
    column_number: int,
}

main :: proc() {
    reader: bufio.Reader
    bufio.reader_init(&reader, os.stream_from_handle(os.stdin))
    content: [dynamic]string
    for {
        line, err := bufio.reader_read_string(&reader, '\n')
        if err == .EOF do break
        append(&content, line)
    }

    errors: [dynamic]Error
    lines: for line, idx in content {
        error := Error {line_idx = idx}
        open_paren := strings.index(line, "(")
        if open_paren < 0 do continue
        error.file_name = line[:open_paren]
        colon := strings.index(line, ":")
        if colon < 0 || colon < open_paren do continue
        for i := open_paren + 1; i < colon; i += 1 {
            if line[i] < '0' || line[i] > '9' do continue lines
        }
        error.line_number = strconv.atoi(line[open_paren + 1:colon])
        close_paren := strings.index(line, ")")
        if close_paren < 0 || close_paren < colon do continue
        for i := colon + 1; i < close_paren; i += 1 {
            if line[i] < '0' || line[i] > '9' do continue lines
        }
        error.column_number = strconv.atoi(line[colon + 1:close_paren])
        append(&errors, error)
    }

    outer: for error, i in errors {
        fmt.printf("\x1B[4m%v\x1B[24m", content[error.line_idx])
        suffix_len: int
        if i + 1 < len(errors) {
            suffix_len = errors[i + 1].line_idx - error.line_idx
        } else {
            suffix_len = len(content) - error.line_idx
        }
        for i := error.line_idx + 1; i < error.line_idx + suffix_len; i += 1 {
            fmt.print(content[i])
        }

        tty, err := os.open("/dev/tty", os.O_RDWR)
        if err != nil {
            fmt.println("Error:", err)
        }
        os.stdin = tty
        buffer: [512]byte
        fmt.print("(n/e): ")
        inner: for {
            len, err := os.read(os.stdin, buffer[:])
            if err != nil {
                fmt.println("Error:", err)
                return
            }
            switch buffer[0] {
                case '\n', 'n': continue outer
                case 'e': break inner
                case: fmt.println("Unknown option:", buffer[0])
            }
        }

        pid, errno := linux.fork()
        if errno != .NONE {
            fmt.println("Error:", errno)
            return
        }
        if pid == 0 {
            argv := []cstring {"hx", fmt.caprintf("%v:%v:%v", error.file_name, error.line_number, error.column_number), nil}
            errno := linux.execve("/usr/bin/hx", raw_data(argv), environ)
            fmt.println("Bruh", errno)
            return
        } else {
            linux.waitpid(pid, nil, nil, nil)
        }
    }
}
