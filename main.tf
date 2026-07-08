
            resource "aws_instance" "web" {
            ami                    = "ami-0287a05f0ef0e9d9a"      
            instance_type          = "t3.medium"
            key_name               = "newkey.pem"              
            vpc_security_group_ids = [aws_security_group.GitHubAction-VM-SG.id]
            user_data              = templatefile("./install.sh", {})

            tags = {
                Name = "GitHubAction-SonarQube"
            }

            root_block_device {
                volume_size = 40
                }
            }

            resource "aws_security_group" "GitHubAction-VM-SG" {
            name        = "GitHubAction-VM-SG"
            description = "Allow TLS inbound traffic"

            ingress = [
                for port in [22, 80, 443, 8080, 9000, 3000] : {
                description      = "inbound rules"
                from_port        = port
                to_port          = port
                protocol         = "tcp"
                cidr_blocks      = ["0.0.0.0/0"]
                ipv6_cidr_blocks = []
                prefix_list_ids  = []
                security_groups  = []
                self             = false
                }
            ]

            egress {
                from_port   = 0
                to_port     = 0
                protocol    = "-1"
                cidr_blocks = ["0.0.0.0/0"]
            }

            tags = {
                Name = "GitHubAction-VM-SG"
                }
            }