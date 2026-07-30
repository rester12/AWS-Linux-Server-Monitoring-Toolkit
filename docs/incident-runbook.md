# Linux Server Health Incident Runbook

## Purpose

Use this runbook to investigate warnings produced by the Linux Server Health Monitoring Toolkit. Run commands only on an authorized lab or managed system. Preserve evidence before making changes, and record the time, symptoms, actions, and results.

## Initial Triage

1. Record the alert name, message, and timestamp.
2. Confirm the EC2 instance state and AWS health indicators.
3. Connect through the approved administrative path.
4. Review the latest monitoring results:

```bash
sudo tail -n 100 /var/log/sys_health.log
sudo systemctl status sys-health-monitor.service
sudo journalctl -u sys-health-monitor.service --since "30 minutes ago"
```

5. Check whether more than one resource is affected before treating warnings as separate incidents.

## Nginx Service or Port Warning

Collect evidence:

```bash
sudo systemctl status nginx
sudo journalctl -u nginx --since "30 minutes ago"
sudo ss -ltnp
sudo nginx -t
sudo tail -n 100 /var/log/nginx/error.log
```

Interpretation:

- If Nginx is inactive, review its journal and configuration test before restarting it.
- If Nginx is active but port 80 is not listening, inspect its bind configuration and error log.
- If `nginx -t` fails while the service remains active, the running process may still be using an older valid configuration.

Recovery:

1. Correct the configuration or restore a known-good copy stored outside directories Nginx automatically loads.
2. Run `sudo nginx -t`.
3. Reload Nginx only after validation succeeds.
4. Confirm port 80 and the expected page:

```bash
sudo systemctl reload nginx
sudo ss -ltnp
curl -I http://127.0.0.1/status.html
```

## High Memory Warning

Collect evidence:

```bash
free -m
ps aux --sort=-%mem | head -n 15
sudo journalctl -k --since "30 minutes ago" | grep -i -E "oom|out of memory"
```

Response:

1. Identify whether the increase is expected, temporary, or abnormal.
2. Avoid terminating processes until their owner and business purpose are understood.
3. Stop only an authorized test workload or follow the application's approved recovery procedure.
4. Confirm available memory returns to an acceptable level.

## High CPU Load Warning

Collect evidence:

```bash
uptime
nproc
ps aux --sort=-%cpu | head -n 15
top -b -n 1 | head -n 25
```

Response:

1. Compare the one-minute load average with the number of logical processors.
2. Identify the process generating load.
3. Determine whether the workload is expected or whether it is blocked on CPU, disk, or another resource.
4. Stop only an authorized test process or follow the approved application procedure.

## High Disk Usage Warning

Collect evidence:

```bash
df -h
sudo du -xhd1 /var/log 2>/dev/null | sort -h
sudo find /var/log -xdev -type f -size +100M -printf '%s %p\n' 2>/dev/null | sort -n
sudo find / -xdev -type f -size +100M -printf '%s %p\n' 2>/dev/null | sort -n
```

Response:

1. Start with the likely path, but use the broader search if the targeted search does not explain the usage.
2. Confirm ownership and purpose before deleting, truncating, compressing, or moving any file.
3. Remove only authorized test files or use the system's approved retention procedure.
4. Confirm filesystem usage returns below the alert threshold.

## SSH Service Warning

Do not close the current administrative session until independent access has been validated.

Collect evidence:

```bash
sudo systemctl status ssh
sudo journalctl -u ssh --since "30 minutes ago"
sudo sshd -t
sudo ss -ltnp | grep ':22'
```

Recovery:

1. Correct syntax or permission errors.
2. Validate with `sudo sshd -t`.
3. Restart the service only after validation succeeds.
4. Test from a second independent session before closing the original connection.

## SNS Notification Failure

Check the instance role and AWS connectivity:

```bash
aws sts get-caller-identity
aws sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN"
sudo journalctl -u sys-health-monitor.service --since "30 minutes ago"
```

Verify that:

- The EC2 instance has the intended IAM role attached.
- The role permits only `sns:Publish` on the intended topic.
- The configured region and topic ARN are correct.
- The topic subscription is confirmed.
- The instance can reach the required AWS API endpoint.

Do not add long-lived AWS access keys to work around an instance-role problem.

## Post-Recovery Validation

```bash
sudo systemctl start sys-health-monitor.service
sudo tail -n 20 /var/log/sys_health.log
curl -I http://127.0.0.1/status.html
```

Confirm:

- The affected check returns to `OK`.
- One recovery notification is sent after a previous warning.
- Repeated healthy runs do not generate unnecessary notifications.
- The dashboard reflects the current condition.
- Temporary test files and workloads have been removed.

## Incident Notes

Record:

- Detection time
- Alert and affected resource
- Evidence collected
- Root cause
- Corrective action
- Recovery time
- Validation results
- Monitoring or runbook improvement identified

