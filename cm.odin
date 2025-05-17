package cm

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

Error :: struct {
    line_idx: int,
    file_name: string,
    line_number: int,
    column_number: int,
}

seconds_to_duration :: proc(seconds: f64) -> time.Duration {
    return cast(time.Duration) (seconds * math.pow_f64(10, 9))
}

print_errors :: proc(errors: []Error, active_error: int, content: []string) {
    fmt.print("\033[H\033[J") // Clear screen
    for error, i in errors {
        if i == active_error {
            fmt.print("\033[7m")
            fmt.println(strings.trim_space(content[error.line_idx]))
            fmt.print("\033[27m")

            suffix_len: int
            if i + 1 < len(errors) {
                suffix_len = errors[i + 1].line_idx - error.line_idx
            } else {
                suffix_len = len(content) - error.line_idx
            }
            for i := error.line_idx + 1; i < error.line_idx + suffix_len; i += 1 {
                fmt.print(content[i])
            }
        } else {
            fmt.println(strings.trim_space(content[error.line_idx]))
        }
    }
}

main :: proc() {
    pipefd: [2]linux.Fd
    if errno := linux.pipe2(&pipefd, {}); errno != .NONE {
        fmt.printfln("ERROR: Can't create pipe: %v", errno)
        os.exit(1)
    }

    pid, errno := linux.fork()
    if errno != .NONE {
        fmt.printfln("ERROR: Can't fork process: %v", errno)
        os.exit(1)
    }

    if pid == 0 {
        if errno := linux.close(pipefd[0]); errno != .NONE {
            fmt.printfln("ERROR: Can't close read end of the pipe: %v", errno)
            os.exit(1)
        }

        // if _, errno := linux.dup2(pipefd[1], linux.STDOUT_FILENO); errno != .NONE {
        //     fmt.printfln("ERROR: Can't redirect stdout to the write end of the pipe: %v", errno)
        //     os.exit(1)
        // }
        if _, errno := linux.dup2(pipefd[1], linux.STDERR_FILENO); errno != .NONE {
            fmt.printfln("ERROR: Can't redirect stderr to the write end of the pipe: %v", errno)
            os.exit(1)
        }
        if errno := linux.close(pipefd[1]); errno != .NONE {
            fmt.printfln("ERROR: Can't close original write end of the pipe: %v", errno)
            os.exit(1)
        }

        argv: [dynamic]cstring
        for arg in os.args[1:] {
            append(&argv, fmt.caprint(arg))
        }
        append(&argv, nil)
        errno := posix.execvp(argv[0], raw_data(argv))
        fmt.printfln("ERROR: Can't replace current process: %v", errno)
    } else {
        if errno := linux.close(pipefd[1]); errno != .NONE {
            fmt.printfln("ERROR: Can't close write end of the pipe: %v", errno)
            os.exit(1)
        }
        defer if errno := linux.close(pipefd[0]); errno != .NONE {
            fmt.printfln("ERROR: Can't close read end of the pipe: %v", errno)
            os.exit(1)
        }
        linux.waitpid(pid, nil, nil, nil)

        reader: bufio.Reader
        bufio.reader_init(&reader, os.stream_from_handle(cast(os.Handle)pipefd[0]))
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

        if len(errors) == 0 { return }

        term: posix.termios
        if result := posix.tcgetattr(posix.STDIN_FILENO, &term); result == .FAIL {
            fmt.eprintln("ERROR: Can't get termios")
            os.exit(1)
        }
    
        nonc_term := term
        nonc_term.c_lflag -= {.ICANON, .ECHO}

        posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &nonc_term)
        fmt.print("\033[H\033[J") // Clear screen

        cursor_line := 0
        quit := false
        b: [1]u8

        print_errors(errors[:], cursor_line, content[:])
        for !quit {
            n, err := os.read(os.stdin, b[:])
            if err != nil {
                fmt.println("ERROR:", err)
                os.exit(1)
            }

            prev_cursor_line := cursor_line
            switch b[0] {
            case 'q': quit = true
            case 'j':
                cursor_line = (cursor_line + 1) % len(errors)
            case 'k':
                cursor_line = int((cast(uint)cursor_line - 1) % len(errors))
            case '\n':
                error := errors[cursor_line]
                cursor_line += 1
                if cursor_line >= len(errors) {
                    quit = true
                }

                pid, errno := linux.fork()
                if errno != .NONE {
                    fmt.println("Error:", errno)
                    return
                }
                if pid == 0 {
                    argv := []cstring {"hx", fmt.caprintf("%v:%v:%v", error.file_name, error.line_number, error.column_number), nil}
                    errno := linux.execve("/usr/bin/hx", raw_data(argv), posix.environ)
                    fmt.println("Bruh", errno)
                    return
                } else {
                    linux.waitpid(pid, nil, nil, nil)
                }
            }

            if cursor_line != prev_cursor_line {
                print_errors(errors[:], cursor_line, content[:])            
            }
        }

        fmt.print("\033[H\033[J") // Clear screen

        posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &term)
    }
}

