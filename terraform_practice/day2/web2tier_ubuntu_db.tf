

##Create a custom VPC
resource "aws_vpc" "web_vpc" {
cidr_block = "10.0.0.0/16"
tags = {
Name = "web-vpc"
}
}

##Create two public subnets for the web tier
resource "aws_subnet" "web_public_subnet_1" {
vpc_id = aws_vpc.web_vpc.id
cidr_block = "10.0.1.0/24"
availability_zone = "us-west-1b"
map_public_ip_on_launch = true
tags = {
Name = "web-public-subnet-1"
}
}

resource "aws_subnet" "web_public_subnet_2" {
vpc_id = aws_vpc.web_vpc.id
cidr_block = "10.0.2.0/24"
availability_zone = "us-west-1c"
map_public_ip_on_launch = true
tags = {
Name = "web-public-subnet-2"
}
}

##Create two private subnets for the RDS tier
resource "aws_subnet" "rds_private_subnet_1" {
vpc_id = aws_vpc.web_vpc.id
cidr_block = "10.0.3.0/24"
availability_zone = "us-west-1b"
tags = {
Name = "rds-private-subnet-1"
}
}

resource "aws_subnet" "rds_private_subnet_2" {
vpc_id = aws_vpc.web_vpc.id
cidr_block = "10.0.4.0/24"
availability_zone = "us-west-1c"
tags = {
Name = "rds-private-subnet-2"
}
}

##Create a public route table and associate it with the public subnets
resource "aws_route_table" "public_route_table" {
vpc_id = aws_vpc.web_vpc.id
route {
cidr_block = "0.0.0.0/0"
gateway_id = aws_internet_gateway.web_igw.id
}
tags = {
Name = "public-route-table"
}
}

resource "aws_route_table_association" "public_route_table_association_1" {
subnet_id      = aws_subnet.web_public_subnet_1.id
route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_route_table_association_2" {
subnet_id      = aws_subnet.web_public_subnet_2.id
route_table_id = aws_route_table.public_route_table.id
}

##Create a private route table and associate it with the private subnets
resource "aws_route_table" "private_route_table" {
vpc_id = aws_vpc.web_vpc.id
route {
cidr_block     = "0.0.0.0/0"
nat_gateway_id = aws_nat_gateway.web_nat_gw.id
}
tags = {
Name = "private-route-table"
}
}

resource "aws_route_table_association" "private_route_table_association_1" {
subnet_id      = aws_subnet.rds_private_subnet_1.id
route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_route_table_association_2" {
subnet_id      = aws_subnet.rds_private_subnet_2.id
route_table_id = aws_route_table.private_route_table.id
}

##Create an internet gateway and attach it to the VPC
resource "aws_internet_gateway" "web_igw" {
vpc_id = aws_vpc.web_vpc.id
tags   = {
Name = "web-igw"
}
}

##Create an elastic IP for the NAT gateway
resource "aws_eip" "web_eip" {
vpc        = true
}

##Create a NAT gateway and place it in one of the public subnets
resource "aws_nat_gateway" "web_nat_gw" {
allocation_id = aws_eip.web_eip.id
subnet_id     = aws_subnet.web_public_subnet_1.id
tags = {
Name = "web-nat-gw"
}
}

##Create a security group for the web tier and allow HTTP and SSH access from anywhere
resource "aws_security_group" "web_sg" {
name        = "web-sg"
description = "Security group for the web tier"
vpc_id      = aws_vpc.web_vpc.id

ingress {
from_port   = 80
to_port     = 80
protocol    = "tcp"
cidr_blocks = ["0.0.0.0/0"]
}

ingress {
from_port   = 22
to_port     = 22
protocol    = "tcp"
cidr_blocks = ["0.0.0.0/0"]
}

egress {
from_port   = 0
to_port     = 0
protocol    = "-1"
cidr_blocks = ["0.0.0.0/0"]
}

tags = {
Name = "web-sg"
}
}

##Create a security group for the RDS tier and allow MySQL access from the web tier
resource "aws_security_group" "rds_sg" {
name        = "rds-sg"
description = "Security group for the RDS tier"
vpc_id      = aws_vpc.web_vpc.id

ingress {
from_port       = 3306
to_port         = 3306
protocol        = "tcp"
security_groups = [aws_security_group.web_sg.id]
}

egress {
from_port   = 0
to_port     = 0
protocol    = "-1"
cidr_blocks = ["0.0.0.0/0"]
}

tags = {
Name = "rds-sg"
}
}

#Create a launch configuration for the web tier and install apache on the EC2 instances
resource "aws_launch_configuration" "web_lc" {
name_prefix          = "web-lc-"
image_id             = "ami-081a3b9eded47f0f3" # Ubuntu Server 20 LTS (HVM), SSD Volume Type
instance_type        = "t2.micro"
security_groups      = [aws_security_group.web_sg.id]

#Use user_data to install apache on the EC2 instances
user_data             = <<-EOF
#!/bin/bash
sudo apt update -y
sudo apt install apache2 -y
sudo systemctl start apache2
sudo systemctl enable apache2
EOF

lifecycle {
#Create_before_destroy = true
}
}

#Create an auto scaling group for the web tier and place it behind an ALB
resource "aws_autoscaling_group" "web_asg" {
name                      = aws_launch_configuration.web_lc.name
launch_configuration      = aws_launch_configuration.web_lc.id
min_size                  = 2 # Launch two EC2 instances in each public subnet in the web tier
max_size                  = 4 # Scale up to four EC2 instances if needed
desired_capacity          = 2 # Start with two EC2 instances
health_check_grace_period = 300 # Wait for 300 seconds before checking the health of the instances
health_check_type         = "ELB" # Use the ELB health check to determine the instance health
vpc_zone_identifier       = [aws_subnet.web_public_subnet_1.id, aws_subnet.web_public_subnet_2.id] # Place the instances in the public subnets
target_group_arns         = [aws_lb_target_group.web_tg.arn] # Register the instances with the target group of the ALB

lifecycle {
#Create_before_destroy = true
}
}

#Create an application load balancer for the web tier and attach a listener and a target group
resource "aws_lb" "web_alb" {
name               = "web-alb"
internal           = false # Make the ALB public-facing
load_balancer_type = "application" # Use an application load balancer
security_groups    = [aws_security_group.web_sg.id] # Use the same security group as the web tier
subnets            = [aws_subnet.web_public_subnet_1.id, aws_subnet.web_public_subnet_2.id] # Place the ALB in the public subnets

tags = {
Name = "web-alb"
}
}

resource "aws_lb_target_group" "web_tg" {
name     = "web-tg"
port     = 80 # Listen on port 80 for HTTP traffic
protocol = "HTTP"
vpc_id   = aws_vpc.web_vpc.id

health_check {
healthy_threshold   = 2 # Consider an instance healthy after two successful health checks
unhealthy_threshold = 2 # Consider an instance unhealthy after two failed health checks
timeout             = 5 # Wait for 5 seconds before timing out a health check
interval            = 30 # Perform a health check every 30 seconds
path                = "/" # Use the root path for the health check
matcher             = "200" # Expect a 200 OK response for a successful health check
protocol            = "HTTP"
port                = "traffic-port" # Use the same port as the traffic port
}

}

resource "aws_lb_listener" "web_listener" {
load_balancer_arn = aws_lb.web_alb.arn # Attach the listener to the ALB
port              = 80 # Listen on port 80 for HTTP traffic
protocol          = "HTTP"

default_action {
type             = "forward" # Forward the traffic to the target group
target_group_arn = aws_lb_target_group.web_tg.arn
}
}

#Create an RDS MySQL instance in the private subnets and configure it with a username and password
resource "aws_db_instance" "web_db" {
allocated_storage    = 20 # Allocate 20 GB of storage
engine               = "mysql" # Use MySQL as the database engine
engine_version       = "8.0.32" # Use MySQL version 8.0.32
instance_class       = "db.t2.micro" # Use a micro instance type
db_name                 = "webdb" # Name the database as webdb
username             = "webadmin" # Set the username as webadmin
password             = "webadmin123" # Set the password as webadmin123
parameter_group_name = "default.mysql8.0" # Use the default parameter group for MySQL 8.0
db_subnet_group_name = aws_db_subnet_group.web_db_subnet_group.name # Place the RDS instance in the private subnets
vpc_security_group_ids = [aws_security_group.rds_sg.id] # Use the security group for the RDS tier

tags = {
Name = "web-db"
}
}

#Create a DB subnet group for the RDS instance and associate it with the private subnets
resource "aws_db_subnet_group" "web_db_subnet_group" {
name       = "web-db-subnet-group"
subnet_ids = [aws_subnet.rds_private_subnet_1.id, aws_subnet.rds_private_subnet_2.id]

tags = {
Name = "web-db-subnet-group"
}
}

#Output the DNS address of the ALB
output "alb_dns_name" {
value = aws_lb.web_alb.dns_name
}