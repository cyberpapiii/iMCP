# Find My People expert preview setup

Find My People is a default-off expert preview. Routine reads are local and read-only, but the one-time key capture
requires you to temporarily weaken macOS startup security, attach LLDB to Apple's `findmylocateagent`, restore the exact
baseline, and reboot. iMCP and its scripts never enter Recovery, change SIP, change boot policy, reboot, or enter a
password for you.

This preview is supported only on the exact macOS build you prove. An OS update, account reset, database recreation, or
key rotation can require a new capture.

## Safety boundary

- Make a current backup and keep another trusted device available before starting.
- Do not continue unless `Scripts/find-my-people-bootstrap.sh --dry-run` passes.
- The scripts capture only the 32-byte `sqlite3_key_v2` key for the canonical `/usr/libexec/findmylocateagent` process and
  a `LocalStorage.db` connection. They do not output or stage the plaintext key.
- The app creates a one-time non-extractable RSA private key in the this-device-only Keychain. The extractor receives
  only its public key and writes an RSA-OAEP ciphertext envelope.
- The external verifier's report is intentionally marked `authoritative: false`. macOS exposes no unprivileged native API
  that can independently sign Full Security, SIP, authenticated-root, and boot-argument state. Import therefore fails
  closed until the report matches the prepared baseline, a reboot occurred, and macOS authenticates the device owner in
  iMCP. This is the explicit user-run import gate; it is not represented as a stronger receipt than it is.

## 1. Record the safe baseline

From a clean checkout, run:

```console
Scripts/find-my-people-bootstrap.sh --dry-run
Scripts/find-my-people-bootstrap.sh baseline
```

The second command asks for administrator authorization only so `bputil` can read the startup security policy. It aborts
unless it proves Full Security, fully enabled SIP, authenticated root, no known AMFI/debug/code-signing weakening boot
argument, and records Developer Tools Security for later equality checking. It writes metadata only under iMCP's private
Application Support directory.

Open iMCP Settings → Location → Find My People and choose **Prepare Setup**. iMCP creates the one-time public
handoff and reveals its private setup folder. Leave People disabled.

Run `Scripts/find-my-people-bootstrap.sh preflight` before changing security. It requires all local dependencies, exactly
one canonical Apple agent, the prepared handoff, and no existing envelope.

## 2. Enter the temporary capture window yourself

These are human-owned operations. Read the current Apple documentation for your exact Mac before proceeding.

1. Shut down the Mac. On Apple silicon, hold the power button until startup options appear, choose Options, and open
   Recovery.
2. In Startup Security Utility, temporarily select the reduced policy required for debugging this Apple process.
3. In Recovery Terminal, disable SIP and authenticated root only for this capture window:

   ```console
   csrutil disable
   csrutil authenticated-root disable
   ```

4. Restart normally. If the pinned extractor instructions for the proven macOS build require an AMFI bypass boot
   argument, enter that command yourself, reboot, and record exactly what changed. Do not add unrelated boot arguments.
5. Run `Scripts/find-my-people-bootstrap.sh capture`. The script performs a final canonical-process preflight, then the
   administrator-authorized LLDB session arms one `sqlite3_key_v2` breakpoint. Open Find My and refresh People. The LLDB
   callback rejects wrong databases and key lengths, encrypts the key in memory, writes one mode-0600 envelope, and
   removes its breakpoint. It prints no key bytes.

If capture is interrupted, run `Scripts/find-my-people-bootstrap.sh cleanup`; then restore security before doing anything
else. Cleanup removes ciphertext reports, while **Cancel Setup** in iMCP removes the one-time private key and handoff.

## 3. Restore security and reboot

Remove every boot argument you added. Return to Recovery yourself, run:

```console
csrutil enable
csrutil authenticated-root enable
```

Restore **Full Security** in Startup Security Utility and restart. Do not call setup complete from the same boot used for
capture.

After the restored reboot, run:

```console
Scripts/find-my-people-bootstrap.sh verify-restored
```

The verifier fails on any missing baseline fact and writes a metadata-only restoration report bound to the exact
ciphertext envelope. In iMCP Settings, choose **Import Encrypted Key** and complete the macOS device-owner authentication.
iMCP checks the new boot, baseline equivalence, envelope digest, installation binding, nonce, database key, schema, and a
real memory-only LocalStorage read before atomically replacing the prior key. A successful import destroys the one-time
private key and staging artifacts. Reusing that envelope or moving it to another installation fails.

Finally enable the separate People gate. Every approved MCP client can then read current People and derived People
history; disabling the gate immediately blocks those reads and stops People sampling without affecting device tools.

## 4. User-run live proof

Automated fixtures do not establish native parity. In one bounded observation window, record only pass/fail and coarse
timing—not names, identifiers, or coordinates—and verify:

| State | Expected result |
| --- | --- |
| Find My open, then closed | Same active share set; locally cached source times remain attributable. |
| Mac locked, then unlocked | No privileged helper or debugger remains; reads resume from the protected local cache. |
| Fresh and stale fixes | iMCP preserves Apple's source time and labels cache lag separately from decode mismatch. |
| Sharing stopped, then restored | The share disappears and returns; a changed Apple server identifier starts a disclosed new history subject. |
| Key rotation or recreated source | People reports a safe recapture state; web device tools continue working. |
| Second restored-security reboot | People still reads with Full Security, SIP, and authenticated root enabled and no bypass boot argument. |

Native parity means the same active share set and source timestamps, with coordinates within the reported horizontal
accuracy plus a small documented comparison tolerance. Do not paste live payloads into issues, logs, commits, or PRs.

## Removal

Settings → **Remove…** asks before doing either of two things. **Clear Key Only** removes the imported database key and
disables People; your friend identifiers and recorded history are kept, and a new capture is needed to read People
again. **Purge Everything** additionally deletes the installation identity, pending setup, and friend-history rows while
retaining device history and named places. Neither action changes Apple's database or Find My sharing state.

