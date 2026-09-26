# CyberArk PSM for SSH deployment

Multihost uses TRAMP and your organization's SSH configuration. It does not
retrieve Vault passwords, change PAM policies, or implement an alternative route
around PSM for SSH (PSMP). The automated test suite uses ordinary OpenSSH on
loopback. **A CyberArk deployment has not been tested or certified by this project.**

## Use an SSH alias

Keep the organization's routing and authentication settings in SSH configuration:

```sshconfig
Host prod-web
    HostName psmp.example.invalid
    User "alice@root@web01.example.invalid"
```

Use `/ssh:prod-web:/srv/operations/` as the inventory connection. Both the target
account and target address are carried in `User`; PSMP is not an ordinary jump
host. Do not add `ProxyJump` unless your organization's connection design requires
it. Keep existing host-key verification, keys, certificates and MFA policy.

CyberArk supports additional routing forms, domains, ports and ticket parameters.
An alias also avoids collisions between its `|` delimiter and TRAMP's multihop
syntax. Ask the PAM administrator for the approved routing string rather than
guessing it. See [CyberArk's connection syntax and remote-command requirements](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/psso-pmsp.htm).

If your Emacs configuration sets a default remote user, ensure that it does not
replace the alias's `User`:

```elisp
(with-eval-after-load 'tramp
  (add-to-list 'tramp-default-user-alist
               '("ssh" "\\`prod-web\\'" nil)))
```

This is the [GNU-documented override for SSH configuration](https://www.gnu.org/software/emacs/manual/html_mono/tramp.html).

## Authentication: interactive versus background

First verify the directory with `C-x C-f /ssh:prod-web:/srv/operations/ RET`.
TRAMP can display authentication prompts in Emacs. The foreground Org command,
`M-x multihost-org-execute-foreground`, uses that Emacs process and is the route
for interactive TRAMP authentication. Authentication depends on the prompts and
methods supported by TRAMP and by the deployment; the command does not automate
OTP entry or guarantee support for every custom login dialogue.

Background runs use persistent isolated batch Emacs workers. Jobs, explicit
warm-up and completion reuse the TRAMP shell inside a worker. This does not
require enabling SSH ControlMaster. Batch authentication prompts fail explicitly;
the pool does not forward MFA challenges into the editor. A successful login in the main
Emacs process does **not** guarantee that a worker can reuse that authentication.
Use an authentication method approved for unattended connections or an explicitly
approved, verified connection-sharing setup. Otherwise use foreground execution.
Never place passwords or OTPs in an inventory, runbook, command line or worker
initialization file. A worker initialization file is trusted executable Emacs Lisp
and should contain configuration, not credentials.

Do not enable TRAMP's direct async optimization solely to avoid authentication
prompts: GNU documents that it cannot perform interactive authentication and has
additional limitations concerning remote signals and multihop connections. See
[TRAMP asynchronous remote processes](https://www.gnu.org/s/emacs/manual/html_node/tramp/Remote-processes.html).

## Connection sharing is a policy decision

Do not assume `ControlMaster` works for every PSMP authentication method. The
CyberArk automation documentation explicitly states a limitation for Vault SSH
key/smart-card authentication with SSH ControlMaster. Its DevOps platform
configuration also changes monitoring and audit behavior: command audits do not
imply that interactive sessions or target-side batch-file contents are recorded.
Review these settings with the PAM administrator. This package does not change
them. See [CyberArk automation configuration and Additional Details](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/configure%20psmp%20to%20support%20devops%20tool.htm).

If approved connection sharing is already configured in SSH, configure TRAMP to
respect it using `tramp-use-connection-share` set to `nil`. TRAMP's automatic
socket locations must not be assumed to match between separate Emacs processes.
Control sockets should live in a private directory and distinguish the complete
remote username, host and port, for example using `%C`. See
[OpenSSH ControlMaster, ControlPath and ControlPersist](https://man.openbsd.org/ssh_config)
and [TRAMP connection sharing](https://www.gnu.org/software/tramp/).

## Capability and audit checks

Remote-command execution, ordinary shell access and SCP/SFTP are distinct
capabilities. CyberArk documents restrictions on remote commands when Commands
Access Control or logon accounts are involved. RADIUS challenges, access reasons
and ticket workflows can require a terminal. A successful plain SSH login is
therefore insufficient evidence that a runbook can execute.

Before using a deployment, validate:

1. Two target aliases reach the correct accounts and machines through PSMP.
2. The permitted script or Babel interpreter works through TRAMP, including any
   required temporary-file operations and working directory.
3. Serial runs wait for completion; parallel runs stay within the approved
   session limit; expired authentication fails visibly or requests a new login.
4. Denied commands remain denied. Neither the package nor a runbook should
   request weakened command controls to work around a rejection.
5. Timeout and cancellation have the expected remote effect. Stopping a local
   worker is not proof that a remote process or its descendants stopped.
6. PAM recording, ticket association and command audit match organizational
   requirements. Local Multihost reports are operational evidence, not a
   replacement for CyberArk's audit system.

Record the PSMP version and platform policy alongside these acceptance results.
The public documentation consulted for this guide was the `latest` documentation
on 2026-09-26; deployment versions and policy combinations can differ.
