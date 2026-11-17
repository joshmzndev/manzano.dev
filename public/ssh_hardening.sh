sudo apt install fail2ban
sudo ufw allow OpenSSH && sudo ufw enable
sudo apt install unattended-upgrades
mkdir -p ~/.ssh
curl -o ~/.ssh/authorized_keys https://manzano.dev/authorized_keys
curl -o /etc/ssh/ssh_config.d/00-ssh-hardening.conf https://manzano.dev/00-ssh-hardening.conf
