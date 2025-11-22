#!/usr/bin/env python3
import boto3, time

ec2 = boto3.client("ec2")

def list_instances_by_tag(project_value: str):
    res = ec2.describe_instances(
        Filters=[{"Name": "tag:Project", "Values": [project_value]},
                 {"Name": "instance-state-name", "Values": ["pending","running","stopping","stopped"]}]
    )
    ids = []
    for r in res["Reservations"]:
        for i in r["Instances"]:
            ids.append(i["InstanceId"])
    return ids

def terminate_instances(ids):
    if not ids:
        print("No instances to terminate.")
        return
    print(f"Terminating instances: {ids}")
    ec2.terminate_instances(InstanceIds=ids)
    try:
        ec2.get_waiter("instance_terminated").wait(InstanceIds=ids)
        print("Instances terminated.")
    except Exception as e:
        print("Waiter error (continuing):", e)

def delete_sgs(prefix: str):
    # list all SGs and delete those starting with prefix
    sgs = ec2.describe_security_groups()["SecurityGroups"]
    # try multiple passes to overcome dependency propagation
    targets = [sg for sg in sgs if sg.get("GroupName","").startswith(prefix)]
    for attempt in range(5):
        remaining = []
        for sg in targets:
            sgid = sg["GroupId"]
            name = sg.get("GroupName")
            try:
                print(f"Deleting SG {name} ({sgid})")
                ec2.delete_security_group(GroupId=sgid)
            except Exception as e:
                print(f"Could not delete SG {name} ({sgid}): {e}")
                remaining.append(sg)
        if not remaining:
            break
        targets = remaining
        time.sleep(5)

def main():
    ids = list_instances_by_tag("final")
    terminate_instances(ids)
    delete_sgs("final-")

if __name__ == "__main__":
    main()