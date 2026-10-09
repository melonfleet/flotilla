Captured 9 October 2026 on the development Mac (macOS 27.0.1, on AC power):

- `pmset-g-macbook-ac.txt` — `pmset -g`, unedited.
- `launchctl-print-disabled-system.txt` — `launchctl print-disabled system`, with every line that is not
  Apple's (`com.apple.*`, `com.openssh.*`) or Flotilla's removed: the rest named the organisation's
  management and security software, which does not belong in a public repository. The lines kept are
  unedited and in their captured order.
- `socketfilterfw-getglobalstate-on.txt` — `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`
  with the firewall on, unedited. Runs without admin rights.
