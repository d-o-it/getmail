# Getmail

Getmail is a small Python script to retrieve emails from IMAP accounts (e.g. gmx.de, gmail.com) and deliver these emails to the Mailcow/Dovecot mailbox. 
I wrote to Getmail because I couldn't find any other solution with IMAP-IDLE in 2018 https://github.com/mailcow/mailcow-dockerized/issues/1554. 
Emails are retrieved using IMAP IDLE, so emails are retrieved immediately and not after a fixed interval (as with imapsync from Mailcow).
The transfer to Mailcow is done via SMTP to Postfix (`postfix-mailcow:25`), so retrieved emails pass rspamd's spam filter like any other incoming mail, and the [sieve rules from Dovecot](https://doc.dovecot.org/configuration_manual/sieve/examples/) still apply (imapsync from Mailcow only allows a fixed folder). The settings keep their `lmtp_` names. The goal of Getmail is to empty the entire INBOX. If the source IMAP account contains emails, you should copy/move them to another folder for testing (e.g. with an email programm or webmail).

Install:
-  Clone getmail
   ```
   cd /opt
   git clone https://github.com/christianbur/getmail.git
   cd /opt/getmail
   ```
- Copy the docker-compose.override.yml file to the mailcow-dockerized folder. Please check if there is already a docker-compose.override.yml in the mailcow directory!!
   ```
   cp /opt/getmail/mailcow-dockerized_docker-compose.override.yml /opt/mailcow-dockerized/docker-compose.override.yml
   ```
- Because the docker network "network-getmail" is used independently in mailcow and getmail, the network "network-getmail" must be created externally (i.e. not in the docker-compose.yml).
  Any other IP range can be used, it should only not be already in use (test: ip show -6 route show, ip show route show).
  ```
   docker network create --driver=bridge --ipv6 --subnet=fdcb:9c90:23:11::/64 --gateway=fdcb:9c90:23:11::1 --subnet=172.23.11.0/24 --gateway=172.23.11.1 -o "com.docker.network.bridge.name"="br-getmail" network-getmail
  ```
- Generate the config from Mailcow's sync jobs. Every **inactive** sync job (Mailcow: E-Mail -> Configuration -> Sync jobs) becomes a getmail job, so Mailcow's own imapsync leaves it alone. The script reads the DB credentials from /opt/mailcow-dockerized/mailcow.conf and writes conf/settings.ini (it contains the IMAP passwords and is not tracked). To write the config by hand instead, start from conf/settings.ini.example.
  ```
   cd /opt/getmail
   ./generate_config.sh
  ```
- Optional: keep the config in sync. watch_changes.sh follows MariaDB's binlog, reruns generate_config.sh whenever a row of the imapsync table is updated (it does not react to INSERT/DELETE, so run generate_config.sh by hand after adding or removing a job) and restarts getmail (with a notification mail) when the config changed.
  ```
   cp /opt/getmail/getmail-changes-watcher.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now getmail-changes-watcher.service
  ```
- Start mailcow and getmail.
  ```
   cd /opt/getmail
   docker compose build 
   docker compose  up -d
  ```
 - Now check the logs from getmail
   ```
   docker compose logs
   ```
    
   
   
   
# Config

Getmail is configured with the configuration file conf/settings.ini. Everything under [DEFAULT] applies to all IMAP accounts. Mostly only imap_hostname:, imap_username:, imap_password: have to be customized. In the source IMAP account only one folder is monitored (default = imap_sync_folder: INBOX), if the junk folder should also be monitored, two accounts must be created. 

 ```
[INBOX_test_gmx.de]
imap_hostname:     imap.gmx.net
imap_username:     test@gmx.de
imap_password:     xxx
# INFO: "imap_sync_folder: INBOX" is default

[JUNK_test_gmx.de]
imap_hostname:     imap.gmx.net
imap_username:     test@gmx.de
imap_password:     xxx
imap_sync_folder:  Junk
```
   
Normally retrieved emails are deleted from the source IMAP account (imap_move_enable: False), the goal of the script is to completely empty the monitored folder (e.g. INBOX). 
It is also possible to move the emails to a folder in the IMAP source account; the emails are then available in both the IMAP source account and the IMAP target account. 
```
imap_move_enable: True
imap_move_folder: getmail
# "getmail" "getmail" is an existing folder in the IMAP source account
```

With 'lmtp_recipient:' you specify the destination imap account in mailcow. 



Sieve filter:
In every retrieved email, two header (X-getmail-retrieved-from-mailbox-user, X-getmail-retrieved-from-mailbox-folder) are added, with this information you can filter with sieve (Mailcow: Mail Setup -> Filters -> Add Filter)

Example:
```
require "fileinto";
require "regex";
require "body";

...
if header :contains ["X-getmail-retrieved-from-mailbox-user"] ["xxxtestxxx@gmx.de", "xxxtest2xxxx@gmx.de"]
{
    fileinto "INBOX/Getmail_GMX";
}
elsif header :contains ["X-getmail-retrieved-from-mailbox-user"] ["xxxtestxxx@outlook.de", "xxxtest2xxxx@outlook.de"]
{
    fileinto "INBOX/Getmail_Outlook";
}
else
{
  # The rest goes into INBOX
  # default is "implicit keep", we do it explicitly here
  keep;
}
```



TZ variable:

The TZ variable defines the time zone of the log timestamps. docker-compose.yml defaults to Europe/Vienna; a global TZ environment variable overrides it, e.g. in /etc/default/locale (reboot may be necessary afterwards):

```
# cat /etc/default/locale
LANG="en_US.UTF-8"
LANGUAGE="en_US:en"
TZ="Europe/Berlin"
```
