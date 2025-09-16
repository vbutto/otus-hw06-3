# Роли сервисного аккаунта для terraform
# iam.serviceAccounts.admin - для создания сервисных аккаунтов
# container-registry.admin - для создания реестра и назначения прав
# vpc.publicAdmin - для создания VPC-сети и подсети
# vpc.privateAdmin - для создания VPC-сети и подсети
# vpc.user
# vpc.securityGroups.admin - для создания security group
# compute.admin - для создания группы ВМ
# ---------------------- Поиск существующего реестра YCR --------------------
# Находим реестр по имени в нужной папке
data "yandex_container_registry" "cr" {
  name      = "hw06-cr-demo"
  folder_id = var.folder_id
}

# ----------------------------- Серваккаунты --------------------------------

# SA для Instance Group (именно им ВМ авторизуются в метадате и тянут образы)
resource "yandex_iam_service_account" "sa_ci_ig" {
  name = "sa-ci-ig"
}

# ВАЖНО: раньше контейнер не стартовал с ошибкой "unauthorized", потому что
# у ВМ не было прав тянуть образ. Решение — дать IG-SA роль puller и привязать
# SA к шаблону ВМ (см. instance_template.service_account_id).
resource "yandex_container_registry_iam_binding" "ig_puller" {
  registry_id = data.yandex_container_registry.cr.id
  role        = "container-registry.images.puller"
  members     = ["serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"]
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_editor" {
  folder_id = var.folder_id
  role      = "editor" # можно сузить набор, оставлено как рабочий минимум для демо
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_vpc_user" {
  folder_id = var.folder_id
  role      = "vpc.user"
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_compute_editor" {
  folder_id = var.folder_id
  role      = "compute.editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_lb_editor" {
  folder_id = var.folder_id
  role      = "load-balancer.editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

# --------------------------------- СЕТЬ ------------------------------------
resource "yandex_vpc_network" "net" {
  name = "net-demo"
}

resource "yandex_vpc_subnet" "sn_a" {
  name           = "sn-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["10.10.0.0/24"]
}

# ---------------------- Контейнер-оптимизированный образ -------------------
data "yandex_compute_image" "coi" {
  family = "container-optimized-image"
}

# ------------------------ Security Group (SSH/8080) ------------------------
# Разрешаем 8080 из Интернета/NLB и SSH только с вашего IP.
resource "yandex_vpc_security_group" "sg_app" {
  name       = "sg-cs-demo"
  network_id = yandex_vpc_network.net.id
  labels     = { env = "hw" }

  # Приложение на 8080 (доступ из Интернета/NLB и хелсчеки)
  ingress {
    protocol       = "TCP"
    description    = "App HTTP (8080)"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 8080
  }

  # SSH: только с твоего IP (var.my_ip наподобие "94.189.254.161/32")
  ingress {
    protocol       = "TCP"
    description    = "SSH from my_ip"
    v4_cidr_blocks = [var.my_ip]
    port           = 22
  }

  # ICMP для отладки (ping)
  ingress {
    protocol       = "ICMP"
    description    = "ICMP (ping)"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Исходящий трафик во внешний мир (pull образов, апдейты и т.п.)
  egress {
    protocol       = "ANY"
    description    = "Egress to Internet"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------- Группа ВМ с декларацией контейнера -------------------
resource "yandex_compute_instance_group" "ig" {
  name               = "cs-demo"
  service_account_id = yandex_iam_service_account.sa_ci_ig.id

  allocation_policy { zones = ["ru-central1-a"] }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
    max_creating    = 1
    max_deleting    = 1
    strategy        = "proactive" # можно опустить, значение по умолчанию
  }

  instance_template {
    platform_id        = "standard-v3"
    service_account_id = yandex_iam_service_account.sa_ci_ig.id # КРИТИЧНО: без этого не будет metadata token -> pull из YCR упадёт

    resources {
      cores         = 2
      memory        = 2
      core_fraction = 20 # требование: 20% CPU
    }

    scheduling_policy {
      preemptible = true
    } # требование: прерываемые ВМ

    boot_disk {
      initialize_params {
        image_id = data.yandex_compute_image.coi.id
        size     = 20
        type     = "network-ssd"
      }
    }

    network_interface {
      subnet_ids         = [yandex_vpc_subnet.sn_a.id]
      nat                = true
      security_group_ids = [yandex_vpc_security_group.sg_app.id]
    }

    metadata = {
      # SSH-ключ: раньше логин/пароль спрашивался, пока ключ не был прописан
      "ssh-keys" = "ubuntu:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEIwAhe9IhThZ8Ed/bZ6h/3CPfX4hhh3DppnRFCadA6L slava.butyrkin@gmail.com"

      # Декларация контейнера:
      # 1) Раньше использовали поле "url" и получали "invalid reference format".
      #    Нужно поле "image" c полным путём вида cr.yandex/<registry_id>/<repo>:tag
      "docker-container-declaration" = jsonencode({
        spec = {
          containers = [{
            name  = "app"
            image = "cr.yandex/${data.yandex_container_registry.cr.id}/hw06-app:1.0"
            ports = [{ name = "http", containerPort = 8080 }]
            env = [
              { name = "PORT", value = "8080" },
              { name = "HOST", value = "0.0.0.0" }
            ]
          }]
          restartPolicy = "Always"
        }
      })
    }
  }

  # Минимальный масштаб
  scale_policy {
    fixed_scale { size = 1 }
  }

  # Target group для NLB
  load_balancer {
    target_group_name = "tg-cs-demo"
  }

  # Health check к контейнеру (настроили после открытия 8080 в SG)
  health_check {
    http_options {
      port = 8080
      path = "/health"
    }
    interval            = 2
    timeout             = 1
    unhealthy_threshold = 5
    healthy_threshold   = 2
  }

  depends_on = [
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_editor,
    yandex_container_registry_iam_binding.ig_puller,
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_vpc_user,
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_compute_editor,
    yandex_resourcemanager_folder_iam_member.sa_ci_ig_lb_editor,
  ]
}

# -------------------------- Публичный L4 балансировщик ---------------------
resource "yandex_lb_network_load_balancer" "nlb" {
  name = "nlb-cs-demo"

  listener {
    name = "http-8080"
    port = 8080
    external_address_spec { ip_version = "ipv4" }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.ig.load_balancer[0].target_group_id

    # Раньше падало из-за имени HC — оно должно соответствовать паттерну:
    # [a-z][-a-z0-9]{1,61}[a-z0-9]  (>= 3 символов, начинается с буквы)
    healthcheck {
      name = "hc-http-8080"
      http_options {
        port = 8080
        path = "/health"
      }
      interval            = 2
      timeout             = 1
      unhealthy_threshold = 5
      healthy_threshold   = 2
    }
  }
}

# Удобный вывод: внешний IP балансировщика
output "nlb_external_ips" {
  value = flatten([
    for l in yandex_lb_network_load_balancer.nlb.listener :
    [for ea in l.external_address_spec : ea.address]
  ])
}
