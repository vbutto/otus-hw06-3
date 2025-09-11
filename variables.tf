# Идентификаторы облака и каталога
variable "cloud_id" {
  description = "Yandex Cloud cloud ID"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

# Зона по умолчанию
variable "zone" {
  description = "Default availability zone"
  type        = string
  default     = "ru-central1-a"
}

# Путь к ключу сервисного аккаунта
variable "sa_key_file" {
  description = "Path to service account key JSON file"
  type        = string
}

# Путь к вашему публичному SSH-ключу
variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "my_ip" {
  description = "Your external IP in CIDR (e.g., 203.0.113.5/32). Empty string means 'open to all' in examples."
  type        = string
  default     = "0.0.0.0/32"
}
