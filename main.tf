# Root main.tf
provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "aws_secondary_region" {
  default = "us-west-2"
}

module "primary" {
  source = "./modules/ecs"
  region = var.aws_region
  environment = "primary"
}

module "secondary" {
  source = "./modules/ecs"
  region = var.aws_secondary_region
  environment = "secondary"
}

# Create Route53 Hosted Zone
resource "aws_route53_zone" "main" {
  name = "yourdomain.com" # Replace with your domain
}

# Primary Region DNS Record
resource "aws_route53_record" "primary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "app"
  type    = "A"

  alias {
    name                   = module.primary.alb_dns_name
    zone_id                = module.primary.alb_zone_id
    evaluate_target_health = true
  }

  set_identifier = "primary"
  failover_routing_policy {
    type = "PRIMARY"
  }
}

# Secondary Region DNS Record
resource "aws_route53_record" "secondary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "app"
  type    = "A"

  alias {
    name                   = module.secondary.alb_dns_name
    zone_id                = module.secondary.alb_zone_id
    evaluate_target_health = true
  }

  set_identifier = "secondary"
  failover_routing_policy {
    type = "SECONDARY"
  }
}

# modules/ecs/main.tf
provider "aws" {
  region = var.region
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "ecs-vpc-${var.region}"
  }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "ecs-subnet-${var.region}"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg-${var.region}"
  description = "Allow inbound HTTP and SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["YOUR_IP/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "alb" {
  name               = "ecs-alb-${var.environment}-${var.region}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = [aws_subnet.main.id]
}

resource "aws_lb_target_group" "ecs_tg" {
  name     = "ecs-tg-${var.environment}-${var.region}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs_tg.arn
  }
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "micro-ui-cluster-${var.region}"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "micro-ui-task-${var.region}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = "micro-ui-container",
      image     = "your-docker-image-url",
      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = "micro-ui-service-${var.region}"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.main.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs_tg.arn
    container_name   = "micro-ui-container"
    container_port   = 80
  }
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}

output "alb_zone_id" {
  value = aws_lb.alb.zone_id
}

# modules/ecs/variables.tf
variable "region" {}
variable "environment" {}
