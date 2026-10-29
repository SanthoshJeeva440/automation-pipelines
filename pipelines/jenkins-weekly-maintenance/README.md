# Jenkins Weekly Maintenance for Ubuntu

This is a starting point for a **package-installed, systemd-managed Jenkins controller**.
It triggers every Sunday around 8 AM using the Jenkins controller timezone, launches an
independent systemd service so it survives Jenkins restarting, backs up `JENKINS_HOME`,
requests plugin updates through the Jenkins Script Console, upgrades only the Jenkins
package, restarts, checks HTTP health, attempts recovery from backup, and sends Gmail SMTP
notification.

## Important limitations

- Test on a disposable/non-production controller first. Unattended plugin/core updates can
  break compatibility. The recovery is best-effort, not a guarantee.
- Not for WAR, Docker, or nonstandard `JENKINS_HOME` installations without adaptation.
- The Jenkins Groovy API is version-sensitive; validate plugin deployment behavior first.
- A full backup can be very large. This script requires >1 GiB free but your installation
  may need much more. Keep a second backup off the device.
- The Weekly repository must already be configured and signed correctly. Official guide:
  https://www.jenkins.io/doc/book/installing/linux/
- Weekly apt source is `https://pkg.jenkins.io/debian`, not `debian-stable`. The runner
  aborts if it sees the LTS repository.
- Only the Jenkins package is upgraded; this does not run a general Ubuntu OS upgrade.

## Install

1. Verify package install and repository:
   `systemctl status jenkins --no-pager`
   `dpkg-query -W -f='${Version}\n' jenkins`
   `grep -Rhs 'pkg.jenkins.io' /etc/apt/sources.list /etc/apt/sources.list.d`

2. Install runner and environment file:
   `sudo install -o root -g root -m 0750 jenkins-weekly-maintenance.sh /usr/local/sbin/jenkins-weekly-maintenance.sh`
   `sudo install -o root -g root -m 0600 jenkins-weekly-maintenance.env.example /etc/jenkins-weekly-maintenance.env`
   `sudo nano /etc/jenkins-weekly-maintenance.env`

3. Fill in Jenkins username/API token and Gmail SMTP settings. Use a Google App Password.
   Never commit secrets. The env file must be root-owned and mode 0600.

4. Add the sudoers rule using `sudo visudo -f /etc/sudoers.d/jenkins-weekly-maintenance`,
   using the example file, then validate with `sudo visudo -cf /etc/sudoers.d/jenkins-weekly-maintenance`.

5. Create a Pipeline job from the included `Jenkinsfile`. Make sure the job runs on the
   controller host (or an agent with systemd access and the exact sudoers setup).

6. Set the Jenkins controller timezone to `Asia/Kolkata` if Sunday 8 AM IST is intended.
   Cron `H 8 * * 0` runs on Sunday at a hash-selected minute during the 8 AM hour.

7. Test manually in a maintenance window:
   `sudo /usr/local/sbin/jenkins-weekly-maintenance.sh`
   Then inspect `/var/log/jenkins-weekly-maintenance.log`, the backup archive, Gmail report,
   `systemctl status jenkins`, and `curl -I http://127.0.0.1:8080/login`.

Do not enable unattended weekly updates until the manual test and recovery path have been
verified on your installation.
