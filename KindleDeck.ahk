#Requires AutoHotkey v2.0
#SingleInstance Force

; Copy this script and index.html into the same Windows folder.
; Change the port here if 8765 is already in use.
PORT := 8765

Persistent()
Deck := DeckServer(PORT)
OnExit((*) => Deck.Stop())
try {
    Deck.Start()
} catch as err {
    MsgBox("Could not start Kindle Deck.`n`n" err.Message, "Kindle Deck", 16)
    ExitApp(1)
}
A_IconTip := "Kindle Deck - port " PORT
A_TrayMenu.Add("Show Kindle connection addresses", (*) => Deck.ShowAddresses())
Deck.ShowAddresses()

class DeckServer {
    __New(port) {
        this.Port := port
        this.Listener := -1
        this.Started := false
        this.Library := 0
        this.Clients := Map()
        this.Tick := ObjBindMethod(this, "Poll")
        this.Hosts := Map()
        this.Addresses := ""
    }

    Start() {
        this.Template := FileRead(A_ScriptDir "\index.html", "UTF-8")
        if !InStr(this.Template, "{{TOKEN}}") || !InStr(this.Template, "{{STATUS}}")
            throw Error("index.html is missing its TOKEN or STATUS placeholder.")
        random := Buffer(32)
        if DllCall("bcrypt\BCryptGenRandom", "Ptr", 0, "Ptr", random,
            "UInt", random.Size, "UInt", 2, "Int") != 0
            throw Error("Could not generate the form token.")
        this.Token := ""
        Loop random.Size
            this.Token .= Format("{:02x}", NumGet(random, A_Index - 1, "UChar"))

        addresses := SysGetIPAddresses()
        addresses.Push("127.0.0.1", "localhost")
        for ip in addresses {
            if ip = "" || ip = "0.0.0.0"
                continue
            this.Hosts[StrLower(ip ":" this.Port)] := true
            if ip != "localhost" && ip != "127.0.0.1"
                this.Addresses .= "http://" ip ":" this.Port "/`n"
        }
        this.Library := DllCall("LoadLibrary", "Str", "Ws2_32.dll", "Ptr")
        if !this.Library
            throw Error("Could not load Windows Sockets.")
        data := Buffer(512, 0)
        result := DllCall("Ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", data, "Int")
        if result != 0
            throw Error("WSAStartup failed: " result)
        this.Started := true
        this.Listener := DllCall("Ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
        if this.Listener = -1
            throw Error("socket failed: " this.LastError())
        exclusive := Buffer(4, 0)
        NumPut("Int", 1, exclusive)
        ; SO_EXCLUSIVEADDRUSE prevents another listener sharing this port.
        this.Check(DllCall("Ws2_32\setsockopt", "Ptr", this.Listener, "Int", 0xFFFF,
            "Int", -5, "Ptr", exclusive, "Int", 4, "Int"), "setsockopt")
        address := Buffer(16, 0)
        NumPut("UShort", 2, address, 0) ; AF_INET, bind all IPv4 interfaces.
        NumPut("UShort", DllCall("Ws2_32\htons", "UShort", this.Port, "UShort"), address, 2)
        this.Check(DllCall("Ws2_32\bind", "Ptr", this.Listener, "Ptr", address,
            "Int", address.Size, "Int"), "bind (is port " this.Port " already in use?)")
        this.Nonblocking(this.Listener)
        this.Check(DllCall("Ws2_32\listen", "Ptr", this.Listener, "Int", 8, "Int"), "listen")
        SetTimer(this.Tick, 30)
    }

    ShowAddresses() {
        addresses := this.Addresses != "" ? this.Addresses : "No LAN IPv4 address found. Connect to Wi-Fi and restart the script.`n"
        MsgBox("On the Kindle, open the address matching your PC's Wi-Fi IPv4 address:`n`n"
            addresses "`nFind that address under the Wi-Fi adapter in ipconfig.`n`n"
            "Test on this PC: http://127.0.0.1:" this.Port "/`n`n"
            "Allow AutoHotkey through Windows Firewall on your Private network.`n"
            "The script stays running in the system tray after you close this message.", "Kindle Deck")
    }

    Nonblocking(socket) {
        mode := Buffer(4, 0)
        NumPut("UInt", 1, mode)
        this.Check(DllCall("Ws2_32\ioctlsocket", "Ptr", socket, "UInt", 0x8004667E,
            "Ptr", mode, "Int"), "ioctlsocket")
    }

    Check(result, operation) {
        if result = -1
            throw Error(operation " failed: " this.LastError())
    }

    LastError() {
        return DllCall("Ws2_32\WSAGetLastError", "Int")
    }

    Poll() {
        ; All socket calls are nonblocking. Bound work per tick keeps the tray responsive.
        Loop 8 {
            socket := DllCall("Ws2_32\accept", "Ptr", this.Listener, "Ptr", 0, "Ptr", 0, "Ptr")
            if socket = -1
                break
            if this.Clients.Count >= 16 {
                DllCall("Ws2_32\closesocket", "Ptr", socket)
                continue
            }
            try this.Nonblocking(socket)
            catch {
                DllCall("Ws2_32\closesocket", "Ptr", socket)
                continue
            }
            this.Clients[socket] := {Input: "", Output: 0, Sent: 0, Since: A_TickCount}
        }
        for socket, client in this.Clients.Clone() {
            if A_TickCount - client.Since > 10000 {
                this.Close(socket)
                continue
            }
            try {
                if !IsObject(client.Output)
                    this.Read(socket, client)
                if this.Clients.Has(socket) && IsObject(client.Output)
                    this.Write(socket, client)
            } catch as err {
                OutputDebug("Kindle Deck: " err.Message)
                this.Close(socket)
            }
        }
    }

    Read(socket, client) {
        chunk := Buffer(4096)
        count := DllCall("Ws2_32\recv", "Ptr", socket, "Ptr", chunk,
            "Int", chunk.Size, "Int", 0, "Int")
        if count = -1 {
            if this.LastError() != 10035 ; WSAEWOULDBLOCK: wait for the next tick.
                this.Close(socket)
            return
        }
        if count = 0 {
            this.Close(socket)
            return
        }
        part := StrGet(chunk, count, "UTF-8")
        ; Requests from this page are ASCII. Reject NULs and ambiguous byte counts.
        if StrLen(part) != count || RegExMatch(part, "[^\x09\x0A\x0D\x20-\x7E]") {
            this.Reply(client, "400 Bad Request", "Invalid request encoding.")
            return
        }
        client.Input .= part
        split := InStr(client.Input, "`r`n`r`n")
        if (!split && StrLen(client.Input) > 8192) || split > 8192 {
            this.Reply(client, "431 Request Header Fields Too Large", "Request headers are too large.")
            return
        }
        if !split
            return
        lines := StrSplit(SubStr(client.Input, 1, split - 1), "`r`n")
        if !RegExMatch(lines[1], "^([A-Z]+) (/[^ ]*) HTTP/1\.[01]$", &request) {
            this.Reply(client, "400 Bad Request", "Invalid request line.")
            return
        }
        headers := Map()
        Loop lines.Length - 1 {
            line := lines[A_Index + 1]
            if !RegExMatch(line, "^([A-Za-z0-9-]+):[ \t]*(.*)$", &header) {
                this.Reply(client, "400 Bad Request", "Invalid header.")
                return
            }
            name := StrLower(header[1])
            if headers.Has(name) {
                this.Reply(client, "400 Bad Request", "Duplicate header.")
                return
            }
            headers[name] := Trim(header[2])
        }
        if !this.Hosts.Has(StrLower(headers.Get("host", ""))) {
            this.Reply(client, "403 Forbidden", "Open this page using the computer's IPv4 address and port.")
            return
        }
        if headers.Has("transfer-encoding") {
            this.Reply(client, "400 Bad Request", "Chunked requests are not supported.")
            return
        }
        length := headers.Get("content-length", "0")
        if !RegExMatch(length, "^\d{1,4}$") || Integer(length) > 1024 {
            this.Reply(client, "413 Content Too Large", "Request body is too large.")
            return
        }
        length := Integer(length)
        if request[1] = "POST" && !headers.Has("content-length") {
            this.Reply(client, "411 Length Required", "Content-Length is required.")
            return
        }
        if StrLen(client.Input) < split + 3 + length
            return ; A TCP packet may contain only part of a form submission.
        body := SubStr(client.Input, split + 4, length)
        this.Route(client, request[1], request[2], headers, body)
    }

    Route(client, method, path, headers, body) {
        if method = "GET" && (path = "/" || RegExMatch(path, "^/\?status=[a-z-]+$")) {
            status := "Ready."
            if path != "/" {
                code := SubStr(path, 10)
                switch code {
                    case "discord": status := "Launch requested: discord."
                    case "notepad": status := "Launch requested: notepad."
                    case "apple-music": status := "Launch requested: apple music."
                    case "discord-missing": status := "File not found: C:\discord.exe"
                    case "notepad-missing": status := "File not found: C:\notepad.exe"
                    case "apple-music-missing": status := "File not found: C:\AppleMusic.exe"
                    case "mute": status := "Mute updated."
                    case "mute-failed": status := "Windows could not change mute. Check your audio output device."
                    case "failed": status := "Windows could not launch the app. Check its path and permissions."
                }
            }
            ; Read Windows state on every page load, including after a toggle.
            muteLabel := "Mute: unavailable (tap to retry)"
            mutePressed := "mixed"
            try {
                muted := SoundGetMute()
                muteLabel := muted ? "Mute: ON (tap to unmute)" : "Mute: OFF (tap to mute)"
                mutePressed := muted ? "true" : "false"
            }
            page := StrReplace(StrReplace(this.Template, "{{TOKEN}}", this.Token), "{{STATUS}}", status)
            page := StrReplace(page, "{{MUTE_LABEL}}", muteLabel)
            page := StrReplace(page, "{{MUTE_PRESSED}}", mutePressed)
            this.Reply(client, "200 OK", page, "text/html; charset=utf-8")
            return
        }
        if path != "/launch" {
            this.Reply(client, "404 Not Found", "Not found. Return to /.")
            return
        }
        if method != "POST" {
            this.Reply(client, "405 Method Not Allowed", "Use the buttons on the home page.",
                "text/plain; charset=utf-8", "Allow: POST`r`n")
            return
        }
        if !RegExMatch(StrLower(headers.Get("content-type", "")),
            "^application/x-www-form-urlencoded(?:[ \t]*;.*)?$") {
            this.Reply(client, "415 Unsupported Media Type", "Expected an HTML form.")
            return
        }
        if !RegExMatch(body, "^token=([0-9a-f]{64})&command=([a-z-]+)$", &form) {
            this.Reply(client, "400 Bad Request", "Invalid form. Return to / and try again.")
            return
        }
        if form[1] !== this.Token {
            this.Reply(client, "403 Forbidden", "This page has expired. Return to / to reload it.")
            return
        }
        ; Only these fixed commands can launch anything. Never execute request text.
        command := form[2]
        switch command {
            case "mute":
                try {
                    SoundSetMute(-1) ; Master mute on the default playback device.
                    result := "mute"
                } catch {
                    result := "mute-failed"
                }
                this.Reply(client, "303 See Other", "Returning to Kindle Deck.",
                    "text/plain; charset=utf-8", "Location: /?status=" result "`r`n")
                return
            case "discord": executable := "C:\discord.exe"
            case "notepad": executable := "C:\notepad.exe"
            case "apple-music": executable := "C:\AppleMusic.exe"
            default:
                this.Reply(client, "400 Bad Request", "Unknown command.")
                return
        }
        if !FileExist(executable) || InStr(FileExist(executable), "D")
            result := command "-missing"
        else {
            try {
                Run('"' executable '"', "C:\")
                result := command
            } catch {
                result := "failed"
            }
        }
        ; POST/Redirect/GET: refreshing the resulting page never relaunches an app.
        this.Reply(client, "303 See Other", "Returning to Kindle Deck.",
            "text/plain; charset=utf-8", "Location: /?status=" result "`r`n")
    }

    Reply(client, status, body, contentType := "text/plain; charset=utf-8", extra := "") {
        size := StrPut(body, "UTF-8") - 1
        response := "HTTP/1.1 " status "`r`nContent-Type: " contentType
            . "`r`nContent-Length: " size "`r`nConnection: close`r`nCache-Control: no-store`r`n"
            . "X-Content-Type-Options: nosniff`r`nX-Frame-Options: DENY`r`n"
            . "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`r`n"
            . extra "`r`n" body
        client.Output := Buffer(StrPut(response, "UTF-8"))
        StrPut(response, client.Output, "UTF-8")
        client.Sent := 0
    }

    Write(socket, client) {
        remaining := client.Output.Size - 1 - client.Sent
        sent := DllCall("Ws2_32\send", "Ptr", socket, "Ptr", client.Output.Ptr + client.Sent,
            "Int", remaining, "Int", 0, "Int")
        if sent = -1 {
            if this.LastError() != 10035
                this.Close(socket)
            return
        }
        client.Sent += sent
        if sent = 0 || client.Sent = client.Output.Size - 1
            this.Close(socket)
    }

    Close(socket) {
        if this.Clients.Has(socket) {
            DllCall("Ws2_32\closesocket", "Ptr", socket)
            this.Clients.Delete(socket)
        }
    }

    Stop() {
        SetTimer(this.Tick, 0)
        for socket in this.Clients.Clone()
            this.Close(socket)
        if this.Listener != -1 {
            DllCall("Ws2_32\closesocket", "Ptr", this.Listener)
            this.Listener := -1
        }
        if this.Started {
            DllCall("Ws2_32\WSACleanup")
            this.Started := false
        }
        if this.Library {
            DllCall("FreeLibrary", "Ptr", this.Library)
            this.Library := 0
        }
    }
}
