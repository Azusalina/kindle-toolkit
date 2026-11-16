# Kindle Deck

A three-button LAN launcher for a Kindle Paperwhite 11th generation (user firmware: 5.20.1) and a Windows computer running AutoHotkey v2.

| Button | Executable |
| --- | --- |
| discord | `C:\discord.exe` |
| notepad | `C:\notepad.exe` |
| apple music | `C:\AppleMusic.exe` |

## Start on Windows

1. Install **AutoHotkey v2** from [autohotkey.com](https://www.autohotkey.com/).
2. Copy `KindleDeck.ahk` and `index.html` into the **same folder** on the Windows computer. Keep both files together. No Node.js, Python, or web hosting is needed.
3. Ensure the three executables exist at the paths above. These are exactly the requested paths, including `C:\notepad.exe`; the script does not substitute a system Notepad path.
4. Double-click `KindleDeck.ahk`. Allow AutoHotkey through Windows Firewall on your **Private** home network if prompted. Normal launch does not need administrator rights.
5. Test `http://127.0.0.1:8765/` in the computer's browser. Tap each button and check that its app opens. A missing executable produces a message on the deck.
6. Open a terminal and run `ipconfig`. Find **IPv4 Address** under the active **Wireless LAN adapter Wi-Fi**, for example `192.168.1.23`. The startup message also lists candidate addresses; ignore VPN and virtual adapter addresses.
7. On the Kindle, connect to the same Wi-Fi, open its web browser, and enter **`http://192.168.1.23:8765/`**, replacing the example with the PC's IPv4 address. Use `http://` and include `:8765`. Bookmark that page.

The Kindle loads the page from the PC. Tapping a button submits an ordinary HTTP POST to the same PC. The AutoHotkey script reads the command, selects the fixed executable with a `switch`, and calls `Run`. It redirects back to the deck with a result message. Refreshing that result page does not submit another launch command. Separate intentional taps each submit a new request; an app may choose to reuse its existing window.

The page uses large black-and-white buttons, basic CSS, and standard HTML forms. It needs no JavaScript, fonts, images, external resources, WebSockets, or background polling. A full page load after each tap gives the e-ink screen a simple interaction pattern. Actual Kindle firmware behavior still needs checking on the device.

## If the Kindle cannot connect

- Keep the PC awake and the AutoHotkey script running. Close the startup message when done reading it; the script remains in the tray. Right-click its tray icon to show the addresses again or choose **Exit** to stop the server.
- First confirm the page works on the PC at `http://127.0.0.1:8765/`. Then try the PC's Wi-Fi address on the PC itself, and finally on the Kindle.
- Check that Windows labels this trusted Wi-Fi network **Private** and that AutoHotkey is allowed through the **Private** firewall profile. Guest networks or wireless client/AP isolation can prevent devices on the same Wi-Fi from reaching one another.
- If an explicit firewall rule is needed, run the following once in **PowerShell as administrator**. It permits this TCP port only on the Private profile, from the local subnet:

  ```powershell
  New-NetFirewallRule -DisplayName "Kindle Deck" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765 -Profile Private -RemoteAddress LocalSubnet
  ```

  Remove this rule later with `Remove-NetFirewallRule -DisplayName "Kindle Deck"`.
- If startup reports a bind error, another program may be using port 8765. Change `PORT` near the top of the script, restart it, and use the new port in the Kindle URL and firewall rule.
- If the PC changes Wi-Fi address, restart the script and update the Kindle bookmark. A DHCP reservation in your router can keep the address stable.
- If a saved page says it has expired after a server restart, return to the root URL (`http://PC-IP:8765/`) to load a fresh form.

## Scope and implementation

The script listens on the PC's IPv4 interfaces. This is intended for a trusted home LAN; devices that can reach the page can use the three buttons. Keep firewall access restricted to your private LAN. Router port forwarding and cloud hosting are unnecessary.

Only the three fixed command names are accepted. Request text is never passed to a shell or used as an executable path. Forms contain a random, per-run token; command execution requires POST with that token. The server checks Host against the PC's startup IPv4 addresses and loopback, limits request size and connection count, and expires incomplete connections. These checks do not provide separate user authentication.

The server uses native [Windows Winsock nonblocking sockets](https://learn.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-ioctlsocket) through AutoHotkey `DllCall`, with a short timer to accept/read/write connections. It handles fragmented requests and [partial sends](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-send). There are no third-party script libraries.

## Verification boundary

Development is on Linux. Static checks verified the three button labels, POST form wiring, token placeholders, and exact executable mappings. This environment blocks local listening ports and browser launch, and its connected browser is unavailable, so visual/browser checks were not completed. AutoHotkey v2 and the Windows application paths cannot be executed here, and the physical Kindle is unavailable.

With `KindleDeck.ahk` running on Windows, optionally run this from the project folder in PowerShell:

```powershell
.\Test-KindleDeck.ps1
```

Use `-Port 9000` if you changed the server port to 9000. The smoke check uses raw TCP requests, including a fragmented form submission. It checks the page and buttons, rejected tokens/commands/hosts, method/content-type/size handling, and the result page. **It does not launch any apps.** The smoke-check script has not been executed on Windows here. Follow the Windows and Kindle steps above to check actual app launches and device behavior.
