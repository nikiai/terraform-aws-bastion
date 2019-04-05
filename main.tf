resource "aws_s3_bucket" "bucket" {
  bucket = "${local.bucket_name}"
  acl    = "bucket-owner-full-control"

  versioning {
    enabled = "${var.bucket_versioning}"
  }

  lifecycle_rule {
    id      = "log"
    enabled = "${var.log_auto_clean}"

    prefix = "logs/"

    tags {
      "rule"      = "log"
      "autoclean" = "${var.log_auto_clean}"
    }

    transition {
      days          = "${var.log_standard_ia_days}"
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = "${var.log_glacier_days}"
      storage_class = "GLACIER"
    }

    expiration {
      days = "${var.log_expiry_days}"
    }
  }

  tags = "${local.tags}"
}

resource "aws_security_group" "private_instances_security_group" {
  name        = "${var.namespace}-${var.stage}-${var.name}"
  description = "Enable SSH access to the bastion host from external via SSH port"
  vpc_id      = "${var.vpc_id}"

  ingress {
    from_port   = "${var.ssh_port}"
    protocol    = "TCP"
    to_port     = "${var.ssh_port}"
    cidr_blocks = "${var.cidrs}"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${local.tags}"
}

resource "aws_iam_role" "host_role" {
  path        = "/"
  name        = "${var.namespace}-${var.stage}-${var.name}"
  description = "Role assigned to bastion instance"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ec2.amazonaws.com"
        ]
      },
      "Action": [
        "sts:AssumeRole"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "host_role_policy" {
  role = "${aws_iam_role.host_role.id}"
  name = "${var.namespace}-${var.stage}-${var.name}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws:s3:::${local.bucket_name}/logs/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${local.bucket_name}/public-keys/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${local.bucket_name}",
      "Condition": {
        "StringEquals": {
          "s3:prefix": "public-keys/"
        }
      }
    }
  ]
}
EOF
}

resource "aws_route53_record" "record_name" {
  name    = "${var.lb_record_name}"
  zone_id = "${var.domain_name}"
  type    = "A"
  count   = "${var.create_dns_record}"

  alias {
    evaluate_target_health = true
    name                   = "${aws_lb.bastion_lb.dns_name}"
    zone_id                = "${aws_lb.bastion_lb.zone_id}"
  }
}

resource "aws_lb" "bastion_lb" {
  internal = "${var.is_lb_private}"

  subnets = [
    "${var.lb_subnets}",
  ]

  load_balancer_type = "network"
  tags               = "${local.tags}"
}

resource "aws_lb_target_group" "lb_target_group" {
  port        = "${var.ssh_port}"
  protocol    = "TCP"
  vpc_id      = "${var.vpc_id}"
  target_type = "instance"

  health_check {
    port     = "traffic-port"
    protocol = "TCP"
  }

  tags = "${local.tags}"
}

resource "aws_lb_listener" "lb_listener_22" {
  "default_action" {
    target_group_arn = "${aws_lb_target_group.lb_target_group.arn}"
    type             = "forward"
  }

  load_balancer_arn = "${aws_lb.bastion_lb.arn}"
  port              = "${var.ssh_port}"
  protocol          = "TCP"
}

resource "aws_iam_instance_profile" "bastion_host_profile" {
  role = "${aws_iam_role.host_role.name}"
  path = "/"
}

module "autoscale_group" {
  source = "git::https://github.com/cloudposse/terraform-aws-ec2-autoscale-group.git?ref=master"

  namespace = "${var.namespace}"
  stage     = "${var.stage}"
  name      = "${var.name}"

  image_id                    = "${data.aws_ami.amazon-linux-2.id}"
  instance_type               = "${var.instance_type}"
  security_group_ids          = ["${aws_security_group.private_instances_security_group.id}"]
  subnet_ids                  = "${var.lb_subnets}"
  health_check_type           = "${var.health_check_type}"
  min_size                    = "${var.min_size}"
  max_size                    = "${var.max_size}"
  associate_public_ip_address = false
  user_data_base64            = "${base64encode(data.template_file.user_data.rendered)}"
  iam_instance_profile_name   = "${aws_iam_instance_profile.bastion_host_profile.name}"
  key_name                    = "${var.key_name}"
  target_group_arns           = ["${aws_lb_target_group.lb_target_group.arn}"]

  tags = {
    vpc                 = "${var.vpc_id}"
    tenancy             = "shared"
    propagate_at_launch = true
  }

  # Auto-scaling policies and CloudWatch metric alarms
  autoscaling_policies_enabled = "${var.auto_scaling_enabled}"
}
