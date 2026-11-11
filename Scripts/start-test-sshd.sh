#!/usr/bin/env bash
# Starts a disposable OpenSSH server on 127.0.0.1:2222 for the RemoteSSH integration tests.
# Linux only, needs root (creates the user `hcgtest`). Never run this on a machine you care about.
#
#   sudo Scripts/start-test-sshd.sh
#   HCG_SSH_TEST=1 swift test --package-path HCGTerminalKit --filter RemoteSSHIntegrationTests
set -euo pipefail
DIR=/tmp/hcg-test-sshd
mkdir -p "$DIR"
id hcgtest >/dev/null 2>&1 || useradd -m -s /bin/bash hcgtest
echo 'hcgtest:hcg-test-pass' | chpasswd
install -d -m 700 -o hcgtest -g hcgtest /home/hcgtest/.ssh
touch /home/hcgtest/.ssh/authorized_keys
chown hcgtest:hcgtest /home/hcgtest/.ssh/authorized_keys
chmod 666 /home/hcgtest/.ssh/authorized_keys   # the test appends its generated key
[ -f "$DIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$DIR/host_ed25519"
mkdir -p /run/sshd
cat > "$DIR/sshd_config" <<CONF
Port 2222
ListenAddress 127.0.0.1
HostKey $DIR/host_ed25519
PidFile $DIR/sshd.pid
UsePAM no
PasswordAuthentication yes
PubkeyAuthentication yes
StrictModes no
AllowUsers hcgtest
AuthorizedKeysFile /home/hcgtest/.ssh/authorized_keys
CONF
[ -f "$DIR/sshd.pid" ] && kill "$(cat "$DIR/sshd.pid")" 2>/dev/null || true
/usr/sbin/sshd -f "$DIR/sshd_config"
echo "sshd on 127.0.0.1:2222; host key: $(ssh-keygen -lf "$DIR/host_ed25519.pub")"
