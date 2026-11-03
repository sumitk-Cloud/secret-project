#!/bin/bash
# =====================================================================
# Centralized Secret Management using AWS Secrets Manager + IAM
# COMMANDS FILE (Git Bash on Windows, region ap-south-1)
#
# Run section by section, NOT as one script.
#   TERMINAL A = Git Bash on your laptop (AWS setup)
#   TERMINAL B = shell on the EC2 instance (SSH or EC2 Instance Connect)
# =====================================================================


# =====================================================================
# STEP 0: VERIFY TOOLS  [TERMINAL A]
# =====================================================================
aws --version
ssh -V
aws configure                  # enter Access Key ID, Secret, region ap-south-1, json
aws sts get-caller-identity


# =====================================================================
# STEP 1: PROJECT FOLDER AND VARIABLES  [TERMINAL A]
# =====================================================================
mkdir -p ~/secret-project && cd ~/secret-project
export MSYS_NO_PATHCONV=1
export AWS_PAGER=""

cat > env.sh <<'EOF'
export MSYS_NO_PATHCONV=1
export AWS_PAGER=""
export AWS_REGION=ap-south-1
export AWS_DEFAULT_REGION=ap-south-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\r\n')/32
export DB_PASS='TempPass1234Demo'
EOF

source env.sh
echo $AWS_REGION $ACCOUNT_ID $MY_IP

# In any new terminal later:
# cd ~/secret-project && source env.sh


# =====================================================================
# STEP 2: KEY PAIR  [TERMINAL A]
# =====================================================================
aws ec2 create-key-pair --key-name devsecops-key \
  --query KeyMaterial --output text > devsecops-key.pem
chmod 400 devsecops-key.pem


# =====================================================================
# STEP 3: SECURITY GROUPS  [TERMINAL A]
# =====================================================================
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query "Vpcs[0].VpcId" --output text)

EC2_SG=$(aws ec2 create-security-group --group-name app-ec2-sg \
  --description "App EC2" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $EC2_SG \
  --protocol tcp --port 22 --cidr $MY_IP

RDS_SG=$(aws ec2 create-security-group --group-name app-rds-sg \
  --description "App RDS" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $RDS_SG \
  --protocol tcp --port 3306 --source-group $EC2_SG

echo "export VPC_ID=$VPC_ID EC2_SG=$EC2_SG RDS_SG=$RDS_SG" >> env.sh
echo $VPC_ID $EC2_SG $RDS_SG


# =====================================================================
# STEP 4: RDS MYSQL (5-10 minutes)  [TERMINAL A]
# =====================================================================
aws rds create-db-instance \
  --db-instance-identifier myapp-db \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --allocated-storage 20 \
  --master-username dbadmin \
  --master-user-password "$DB_PASS" \
  --db-name appdb \
  --vpc-security-group-ids $RDS_SG \
  --no-publicly-accessible \
  --storage-encrypted

aws rds wait db-instance-available --db-instance-identifier myapp-db

RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier myapp-db \
  --query "DBInstances[0].Endpoint.Address" --output text)
echo $RDS_HOST
echo "export RDS_HOST=$RDS_HOST" >> env.sh

# Check status any time:
# aws rds describe-db-instances --db-instance-identifier myapp-db \
#   --query "DBInstances[0].DBInstanceStatus" --output text


# =====================================================================
# STEP 5: LAUNCH EC2 (NO IAM ROLE YET)  [TERMINAL A]
# =====================================================================
AMI=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
  --key-name devsecops-key --security-group-ids $EC2_SG \
  --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=secrets-demo}]' \
  --query "Instances[0].InstanceId" --output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID

EC2_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "export INSTANCE_ID=$INSTANCE_ID EC2_IP=$EC2_IP" >> env.sh
echo $INSTANCE_ID $EC2_IP


# =====================================================================
# STEP 6A: CONNECT TO EC2  [TERMINAL A]
# =====================================================================
# Option 1: SSH
ssh -i devsecops-key.pem ec2-user@$EC2_IP

# Option 2: if port 22 is blocked on your network, use the browser terminal:
#   Console -> EC2 -> Instances -> secrets-demo -> Connect -> EC2 Instance Connect
#   First allow the Instance Connect range for ap-south-1 (verify it):
#   curl -s https://ip-ranges.amazonaws.com/ip-ranges.json | \
#     grep -A3 -B3 '"EC2_INSTANCE_CONNECT"' | grep -A5 -B1 'ap-south-1'
#   aws ec2 authorize-security-group-ingress --group-id $EC2_SG \
#     --protocol tcp --port 22 --cidr <RANGE_FROM_ABOVE>


# =====================================================================
# STEP 6B: "BEFORE" DEMO, HARDCODED SECRET  [TERMINAL B - on EC2]
# =====================================================================
sudo dnf install -y python3-pip mariadb105
pip3 install --user pymysql boto3
mkdir -p ~/secret-demo && cd ~/secret-demo

export RDS_HOST=<PASTE_YOUR_RDS_ENDPOINT>
export DB_PASS='TempPass1234Demo'

mysql -h $RDS_HOST -u dbadmin -p"$DB_PASS" appdb -e \
"CREATE TABLE IF NOT EXISTS employees (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50));
 INSERT INTO employees (name) VALUES ('Alice'),('Bob'),('Charlie');"

cat > config.ini <<EOF
[database]
host = $RDS_HOST
user = dbadmin
password = $DB_PASS
name = appdb
EOF

cat > app_hardcoded.py <<'EOF'
import configparser
import pymysql

cfg = configparser.ConfigParser()
cfg.read("config.ini")
db = cfg["database"]

conn = pymysql.connect(host=db["host"], user=db["user"],
                       password=db["password"], database=db["name"],
                       connect_timeout=5)
with conn.cursor() as cur:
    cur.execute("SELECT id, name FROM employees")
    for row in cur.fetchall():
        print(row)
conn.close()
print("[INSECURE] Connected using hardcoded credentials from config.ini")
EOF

python3 app_hardcoded.py        # SCREENSHOT 1
cat config.ini                  # SCREENSHOT 2 (exposed password)


# =====================================================================
# STEP 7: CREATE THE SECRETS  [TERMINAL A - laptop]
# =====================================================================
cd ~/secret-project && source env.sh

aws secretsmanager create-secret \
  --name prod/myapp/db \
  --description "DB credentials for myapp" \
  --secret-string "{\"username\":\"dbadmin\",\"password\":\"$DB_PASS\",\"engine\":\"mysql\",\"host\":\"$RDS_HOST\",\"port\":3306,\"dbname\":\"appdb\"}"

# Dummy secret for the AccessDenied test
aws secretsmanager create-secret --name test/other --secret-string '{"x":"y"}'


# =====================================================================
# STEP 8: IAM ROLE, POLICY, INSTANCE PROFILE  [TERMINAL A]
# =====================================================================
cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > secret-read-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyThisSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:prod/myapp/db-*"
    }
  ]
}
EOF

aws iam create-role --role-name EC2-SecretReader-Role \
  --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy --role-name EC2-SecretReader-Role \
  --policy-name ReadProdMyappDbSecret \
  --policy-document file://secret-read-policy.json

aws iam create-instance-profile --instance-profile-name EC2-SecretReader-Profile
aws iam add-role-to-instance-profile \
  --instance-profile-name EC2-SecretReader-Profile \
  --role-name EC2-SecretReader-Role

sleep 15    # let IAM propagate

aws ec2 associate-iam-instance-profile --instance-id $INSTANCE_ID \
  --iam-instance-profile Name=EC2-SecretReader-Profile

# Verify attachment
aws ec2 describe-iam-instance-profile-associations \
  --filters Name=instance-id,Values=$INSTANCE_ID \
  --query "IamInstanceProfileAssociations[0].[State,IamInstanceProfile.Arn]" --output text

# SCREENSHOT: IAM console -> role, trust relationship, permissions policy


# =====================================================================
# STEP 9: "AFTER" APP, SECURE VERSION  [TERMINAL B - on EC2]
# =====================================================================
cd ~/secret-demo

cat > app_secure.py <<'EOF'
import json
import os
import boto3
import pymysql
from botocore.exceptions import ClientError

SECRET_NAME = os.environ.get("SECRET_NAME", "prod/myapp/db")
REGION = os.environ.get("AWS_REGION", "ap-south-1")


def get_db_secret():
    client = boto3.client("secretsmanager", region_name=REGION)
    try:
        resp = client.get_secret_value(SecretId=SECRET_NAME)
    except ClientError as e:
        print(f"Failed to fetch secret: {e.response['Error']['Code']}")
        raise
    return json.loads(resp["SecretString"])


def main():
    s = get_db_secret()
    print(f"[SECURE] Secret retrieved for user: {s['username']} (password not logged)")

    conn = pymysql.connect(host=s["host"], user=s["username"],
                           password=s["password"], database=s["dbname"],
                           port=int(s.get("port", 3306)), connect_timeout=5)
    with conn.cursor() as cur:
        cur.execute("SELECT id, name FROM employees")
        for row in cur.fetchall():
            print(row)
    conn.close()
    print("[SECURE] Connected to DB using credentials from Secrets Manager")


if __name__ == "__main__":
    main()
EOF

# Remove all hardcoded secrets
shred -u config.ini
rm -f app_hardcoded.py
unset DB_PASS RDS_HOST
history -c

export AWS_REGION=ap-south-1
python3 app_secure.py           # SCREENSHOT 3 (secret retrieval)


# =====================================================================
# STEP 10: SECURITY VALIDATION  [TERMINAL B - on EC2, screenshot each]
# =====================================================================
aws configure list --region ap-south-1          # no static keys, type iam-role
ls -la ~/.aws 2>&1                              # No such file or directory
env | grep -i AWS_                              # no access keys
grep -rni "password" ~/secret-demo              # only variable names, no values
aws sts get-caller-identity --region ap-south-1 # assumed-role/EC2-SecretReader-Role

# Least privilege: must FAIL with AccessDeniedException
aws secretsmanager get-secret-value --secret-id test/other --region ap-south-1

# Allowed secret: must WORK
aws secretsmanager get-secret-value --secret-id prod/myapp/db --region ap-south-1 \
  --query Name --output text

python3 app_secure.py                           # rows printed


# =====================================================================
# STEP 11: OPTIONAL AUTOMATIC ROTATION
# =====================================================================
# Easiest in console:
#   Secrets Manager -> prod/myapp/db -> Rotation configuration -> Edit rotation
#   Enable, 30 days, Create a rotation function
# CLI (needs an existing rotation Lambda):
# aws secretsmanager rotate-secret --secret-id prod/myapp/db \
#   --rotation-lambda-arn <LAMBDA_ARN> \
#   --rotation-rules AutomaticallyAfterDays=30


# =====================================================================
# STEP 12: AUDIT EVIDENCE (CLI alternative to console)  [TERMINAL A]
# =====================================================================
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
  --max-results 5 \
  --query "Events[*].[EventTime,Username,EventName]" --output table
# Or: Console -> CloudTrail -> Event history -> Event name = GetSecretValue


# =====================================================================
# STEP 13: REPO AND README  [TERMINAL A]
# =====================================================================
cd ~/secret-project
mkdir -p screenshots

# If SSH works:
scp -i devsecops-key.pem ec2-user@$EC2_IP:~/secret-demo/app_secure.py .
# If you used Instance Connect: run `cat app_secure.py` on EC2 and paste into a local file.

git init
printf "*.pem\nenv.sh\nconfig.ini\n*.csv\n" > .gitignore
git add .
git commit -m "Centralized secrets management project"


# =====================================================================
# STEP 14: CLEANUP (to avoid charges)  [TERMINAL A]
# =====================================================================
cd ~/secret-project && source env.sh

aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID

aws rds delete-db-instance --db-instance-identifier myapp-db --skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier myapp-db

aws secretsmanager delete-secret --secret-id prod/myapp/db --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id test/other --force-delete-without-recovery

aws iam remove-role-from-instance-profile \
  --instance-profile-name EC2-SecretReader-Profile --role-name EC2-SecretReader-Role
aws iam delete-instance-profile --instance-profile-name EC2-SecretReader-Profile
aws iam delete-role-policy --role-name EC2-SecretReader-Role --policy-name ReadProdMyappDbSecret
aws iam delete-role --role-name EC2-SecretReader-Role

aws ec2 delete-security-group --group-id $RDS_SG
aws ec2 delete-security-group --group-id $EC2_SG
aws ec2 delete-key-pair --key-name devsecops-key

# Finally, delete the admin access key in IAM:
#   IAM -> Users -> devops-admin -> Security credentials -> Access keys -> Delete


# =====================================================================
# TROUBLESHOOTING QUICK COMMANDS
# =====================================================================
# SSH times out (IP changed):
#   export MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\r\n')/32
#   aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 22 --cidr $MY_IP
# Test port 22 from laptop:
#   timeout 5 bash -c "</dev/tcp/$EC2_IP/22" && echo OPEN || echo BLOCKED
# Instance health:
#   aws ec2 describe-instance-status --instance-ids $INSTANCE_ID \
#     --query "InstanceStatuses[0].[InstanceStatus.Status,SystemStatus.Status]" --output text
# AccessDenied right after attaching role: wait 30-60 seconds and retry.