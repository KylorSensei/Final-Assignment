#!/usr/bin/env python3
import os, time, json, boto3

PROJECT = "final"

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")


def get_default_vpc_id():
    vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
    if not vpcs:
        raise SystemExit("No default VPC found.")
    return vpcs[0]["VpcId"]


def get_default_subnet_id(vpc_id: str) -> str:
    subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"]
    if not subnets:
        raise SystemExit("No subnet found in the default VPC.")
    subs_sorted = sorted(subnets, key=lambda s: (not s.get("MapPublicIpOnLaunch", False), s["SubnetId"]))
    return subs_sorted[0]["SubnetId"]


def get_ubuntu_ami() -> str:
    param = ssm.get_parameter(
        Name="/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
    )
    return param["Parameter"]["Value"]


def create_sgs(vpc_id: str):
    ts = str(int(time.time()))
    sg_gk = ec2.create_security_group(VpcId=vpc_id, GroupName=f"final-gk-{ts}", Description="Gatekeeper SG")["GroupId"]
    sg_proxy = ec2.create_security_group(VpcId=vpc_id, GroupName=f"final-proxy-{ts}", Description="Proxy SG")["GroupId"]
    sg_mysql = ec2.create_security_group(VpcId=vpc_id, GroupName=f"final-mysql-{ts}", Description="MySQL SG")["GroupId"]

    # Gatekeeper: HTTP 80 + SSH 22 for simplicity
    ec2.authorize_security_group_ingress(
        GroupId=sg_gk,
        IpPermissions=[
            {"IpProtocol": "tcp", "FromPort": 80, "ToPort": 80, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
            {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
        ],
    )

    # Proxy: only 8080 from Gatekeeper SG (+ SSH for deployment)
    ec2.authorize_security_group_ingress(
        GroupId=sg_proxy,
        IpPermissions=[
            {"IpProtocol": "tcp", "FromPort": 8080, "ToPort": 8080, "UserIdGroupPairs": [{"GroupId": sg_gk}]},
            {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
        ],
    )

    # MySQL: 3306 from Proxy SG and intra-MySQL (replication) (+ SSH for simple admin if needed)
    ec2.authorize_security_group_ingress(
        GroupId=sg_mysql,
        IpPermissions=[
            {"IpProtocol": "tcp", "FromPort": 3306, "ToPort": 3306, "UserIdGroupPairs": [{"GroupId": sg_proxy}, {"GroupId": sg_mysql}]},
            {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
        ],
    )
    return sg_gk, sg_proxy, sg_mysql


def user_data_gatekeeper() -> str:
    return """#!/bin/bash
set -eux
apt-get update -y
apt-get install -y python3 python3-pip
"""


def user_data_proxy() -> str:
    return """#!/bin/bash
set -eux
apt-get update -y
apt-get install -y python3 python3-pip
"""


def user_data_mysql() -> str:
    return """#!/bin/bash
set -eux
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server sysbench
systemctl enable --now mysql
"""


def tags(role: str, dbrole: str | None = None):
    t = [{"Key": "Project", "Value": PROJECT}, {"Key": "Role", "Value": role}]
    if dbrole:
        t.append({"Key": "DbRole", "Value": dbrole})
    return t


def main() -> None:
    key_name = os.environ.get("KEY_NAME")
    if not key_name:
        raise SystemExit("Please set KEY_NAME to an existing EC2 key pair name.")
    region = os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
    print(f"Region: {region} | Key: {key_name}")

    vpc_id = get_default_vpc_id()
    subnet_id = get_default_subnet_id(vpc_id)
    sg_gk, sg_proxy, sg_mysql = create_sgs(vpc_id)
    ami = get_ubuntu_ami()
    print(f"Using AMI: {ami} | Subnet: {subnet_id}")

    # Gatekeeper (t2.large, public)
    gk = ec2.run_instances(
        ImageId=ami,
        InstanceType="t2.large",
        MinCount=1,
        MaxCount=1,
        KeyName=key_name,
        TagSpecifications=[{"ResourceType": "instance", "Tags": tags("gatekeeper")}],
        NetworkInterfaces=[
            {"DeviceIndex": 0, "SubnetId": subnet_id, "AssociatePublicIpAddress": True, "Groups": [sg_gk]}
        ],
        UserData=user_data_gatekeeper(),
    )

    # Proxy (t2.large, public IP for simplicity; SG restricts exposure)
    px = ec2.run_instances(
        ImageId=ami,
        InstanceType="t2.large",
        MinCount=1,
        MaxCount=1,
        KeyName=key_name,
        TagSpecifications=[{"ResourceType": "instance", "Tags": tags("proxy")}],
        NetworkInterfaces=[
            {"DeviceIndex": 0, "SubnetId": subnet_id, "AssociatePublicIpAddress": True, "Groups": [sg_proxy]}
        ],
        UserData=user_data_proxy(),
    )

    # MySQL manager (t2.micro)
    mgr = ec2.run_instances(
        ImageId=ami,
        InstanceType="t2.micro",
        MinCount=1,
        MaxCount=1,
        KeyName=key_name,
        TagSpecifications=[{"ResourceType": "instance", "Tags": tags("mysql", "manager")}],
        NetworkInterfaces=[
            {"DeviceIndex": 0, "SubnetId": subnet_id, "AssociatePublicIpAddress": True, "Groups": [sg_mysql]}
        ],
        UserData=user_data_mysql(),
    )

    # MySQL workers (2 × t2.micro)
    wrk = ec2.run_instances(
        ImageId=ami,
        InstanceType="t2.micro",
        MinCount=2,
        MaxCount=2,
        KeyName=key_name,
        TagSpecifications=[{"ResourceType": "instance", "Tags": tags("mysql", "worker")}],
        NetworkInterfaces=[
            {"DeviceIndex": 0, "SubnetId": subnet_id, "AssociatePublicIpAddress": True, "Groups": [sg_mysql]}
        ],
        UserData=user_data_mysql(),
    )

    all_ids = [gk["Instances"][0]["InstanceId"], px["Instances"][0]["InstanceId"], mgr["Instances"][0]["InstanceId"]] + [
        i["InstanceId"] for i in wrk["Instances"]
    ]
    print("Waiting for instances to be running...")
    ec2.get_waiter("instance_running").wait(InstanceIds=all_ids)
    desc = ec2.describe_instances(InstanceIds=all_ids)["Reservations"]

    info = {"gatekeeper": {}, "proxy": {}, "mysql": {"manager": {}, "workers": []}}
    for r in desc:
        for it in r["Instances"]:
            iid = it["InstanceId"]
            pub = it.get("PublicIpAddress")
            priv = it.get("PrivateIpAddress")
            role = next((t["Value"] for t in it.get("Tags", []) if t["Key"] == "Role"), "")
            dbrole = next((t["Value"] for t in it.get("Tags", []) if t["Key"] == "DbRole"), "")
            if role == "gatekeeper":
                info["gatekeeper"] = {"id": iid, "public_ip": pub, "private_ip": priv}
            elif role == "proxy":
                info["proxy"] = {"id": iid, "public_ip": pub, "private_ip": priv}
            elif role == "mysql" and dbrole == "manager":
                info["mysql"]["manager"] = {"id": iid, "public_ip": pub, "private_ip": priv}
            elif role == "mysql" and dbrole == "worker":
                info["mysql"]["workers"].append({"id": iid, "public_ip": pub, "private_ip": priv})

    os.makedirs("Final/infra", exist_ok=True)
    with open("Final/infra/instances.json", "w", encoding="utf-8") as f:
        json.dump(info, f, indent=2)

    os.makedirs("Final/proxy", exist_ok=True)
    proxy_cfg = {
        "manager": {"host": info["mysql"]["manager"]["private_ip"], "port": 3306},
        "workers": [{"host": w["private_ip"], "port": 3306} for w in info["mysql"]["workers"]],
        "listen_port": 8080,
    }
    with open("Final/proxy/config.json", "w", encoding="utf-8") as f:
        json.dump(proxy_cfg, f, indent=2)

    os.makedirs("Final/scripts", exist_ok=True)
    with open("Final/scripts/gatekeeper_ip.txt", "w") as f:
        f.write(info["gatekeeper"].get("public_ip", ""))
    with open("Final/scripts/proxy_private_ip.txt", "w") as f:
        f.write(info["proxy"].get("private_ip", ""))

    print("Wrote Final/infra/instances.json and Final/proxy/config.json")
    print("Gatekeeper public IP:", info["gatekeeper"].get("public_ip"))
    print("Proxy private IP:", info["proxy"].get("private_ip"))


if __name__ == "__main__":
    main()