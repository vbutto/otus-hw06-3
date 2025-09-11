# Роли сервисного аккаунта
# iam.serviceAccounts.admin - для создания сервисных аккаунтов
# container-registry.admin - для создания реестра и назначения прав
# vpc.publicAdmin - для создания VPC-сети и подсети
# vpc.privateAdmin - для создания VPC-сети и подсети
# compute.admin - для создания группы ВМ


# --- Поиск существующего реестра образов (YCR) ---------------------------
# Находим реестр по имени в нужной папке. Из него берём registry_id.
data "yandex_container_registry" "cr" {
  name      = "hw06-cr-demo"
  folder_id = var.folder_id
}

# --- Вспомогательный вывод: проверяем, что нашли нужный реестр ----------
output "cr_id" {
  value = data.yandex_container_registry.cr.id
}

resource "yandex_iam_service_account" "sa_ci" {
  name = "sa-ci"
}

resource "yandex_container_registry_iam_binding" "pusher" {
  registry_id = data.yandex_container_registry.cr.id
  role        = "container-registry.images.pusher"
  members     = ["serviceAccount:${yandex_iam_service_account.sa_ci.id}"]
}


# создаем контейнер в Container Solution

# ---- сеть ----
resource "yandex_vpc_network" "net" {
  name = "net-demo"
}

resource "yandex_vpc_subnet" "sn_a" {
  name           = "sn-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["10.10.0.0/24"]
}

# ---- SA для IG (он будет тянуть образы) ----
resource "yandex_iam_service_account" "sa_ci_ig" {
  name = "sa-ci-ig"
}

# Разрешаем этому SA тянуть образы из CR
resource "yandex_container_registry_iam_binding" "ig_puller" {
  registry_id = data.yandex_container_registry.cr.id
  role        = "container-registry.images.puller"
  members     = ["serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"]
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_editor" {
  folder_id = var.folder_id
  role      = "editor" # можно "editor" если не хочешь размазывать роли
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_vpc_user" {
  folder_id = var.folder_id
  role      = "vpc.user"
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_compute_editor" {
  folder_id = var.folder_id
  role      = "compute.editor" # можно compute.admin, но editor обычно достаточно
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_ci_ig_lb_editor" {
  folder_id = var.folder_id
  role      = "load-balancer.editor" # можно .admin, но editor обычно достаточно
  member    = "serviceAccount:${yandex_iam_service_account.sa_ci_ig.id}"
}


# ---- контейнер-оптимизированный образ ----
data "yandex_compute_image" "coi" {
  family = "container-optimized-image"
}

# ---- группа ВМ с декларацией контейнера ----
resource "yandex_compute_instance_group" "ig" {
  name               = "cs-demo"
  service_account_id = yandex_iam_service_account.sa_ci_ig.id

  allocation_policy { zones = ["ru-central1-a"] }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
    max_creating    = 1
    max_deleting    = 1
    strategy        = "proactive" # по умолчанию; можно опустить
  }

  instance_template {
    platform_id = "standard-v3"
    resources {
      cores  = 2
      memory = 2
    }

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

    # Декларация контейнера — JSON строкой
    metadata = {
      "docker-container-declaration" = jsonencode({
        spec = {
          containers = [{
            name = "app"
            url  = "cr.yandex/${data.yandex_container_registry.cr.id}/hw06-app:1.0"
            # если нужно — command/args/env
            ports = [{ name = "http", containerPort = 8080 }]
            env   = [{ name = "PORT", value = "8080" }]
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

  # Здоровье контейнера
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

# ---- Публичный L4 балансировщик ----
resource "yandex_lb_network_load_balancer" "nlb" {
  name = "nlb-cs-demo"

  listener {
    name = "http-8080"
    port = 8080
    external_address_spec { ip_version = "ipv4" }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.ig.load_balancer[0].target_group_id
    healthcheck {
      name = "hc"
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

output "nlb_external_ips" {
  value = flatten([
    for l in yandex_lb_network_load_balancer.nlb.listener :
    [for ea in l.external_address_spec : ea.address]
  ])
}

# ---- Security Group для трафика через NLB ----
resource "yandex_vpc_security_group" "sg_app" {
  name       = "sg-cs-demo"
  network_id = yandex_vpc_network.net.id
  labels     = { env = "hw" }

  # Разрешаем вход на порт приложения (8080) снаружи через NLB
  ingress {
    protocol       = "TCP"
    description    = "App HTTP from Internet via NLB"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 8080
  }

  # (опционально) Пинг для отладки
  ingress {
    protocol       = "ICMP"
    description    = "ICMP (ping)"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Исходящий — в Интернет (обновления, pull образов и т.п.)
  egress {
    protocol       = "ANY"
    description    = "Egress to Internet"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
