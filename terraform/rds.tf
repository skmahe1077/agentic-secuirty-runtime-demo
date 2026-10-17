resource "random_password" "db_master" {
  length  = 24
  special = false # keep it psql-copy-paste-friendly during setup
}

resource "aws_db_subnet_group" "nimbus" {
  name       = "${var.name}-db-subnets"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.name}-rds-"
  description = "PostgreSQL access for the Nimbus Store demo DB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "from EKS nodes -- covers both the storefront connection and Vault database secrets engine, which runs in-cluster and egresses the node ENI"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = var.name }
}

resource "aws_db_instance" "nimbus" {
  identifier     = "${var.name}-nimbus"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = var.db_name
  username = var.db_master_username
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.nimbus.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false
  multi_az            = false # a demo stack torn down daily does not need multi-AZ
  skip_final_snapshot = true
  deletion_protection = false # this MUST be destroyable by scripts/destroy.sh between rehearsals

  tags = { Project = var.name }
}
