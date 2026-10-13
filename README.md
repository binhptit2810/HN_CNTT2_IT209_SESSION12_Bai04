# BÀI 4: TỰ ĐỘNG TRIỂN KHAI ỨNG DỤNG SPRING BOOT (CONTAINER) LÊN VPS TỪ XA QUA SSH

## 1. Mục tiêu bài tập
* **Tự động hóa CI/CD**: Khi có commit mới được đẩy lên nhánh `main` hoặc `master`, GitHub Actions tự động build ứng dụng Spring Boot thành Docker Image, đóng gói và đẩy lên **GitHub Container Registry (GHCR)**.
* **Triển khai từ xa qua SSH (SSH Action)**: Sử dụng action `appleboy/ssh-action@v1.0.3` để tự động kết nối đến máy chủ VPS thông qua SSH, thực thi các lệnh:
  1. Đăng nhập vào GHCR trên máy chủ VPS.
  2. Kéo (pull) image Docker mới nhất về VPS.
  3. Dừng và xóa container phiên bản cũ (nếu có).
  4. Khởi chạy container mới với port mapping `8080:8080`.
* **Kiểm tra & Giám sát**: Xác nhận dịch vụ hoạt động thông qua Spring Boot Actuator endpoint (`/actuator/health`) trả về HTTP 200 OK (`{"status":"UP"}`).

---

## 2. Cấu trúc thư mục dự án
```text
homework/session_12/ex4/
├── .github/
│   └── workflows/
│       └── deploy-vps.yml              # Kịch bản CI/CD GitHub Actions
├── src/                                # Mã nguồn Spring Boot (Java 17)
│   ├── main/
│   │   ├── java/com/example/demo/
│   │   │   ├── DemoApplication.java
│   │   │   └── controller/HelloController.java
│   │   └── resources/
│   │       └── application.properties  # Cấu hình Spring Boot Actuator
│   └── test/                           # Unit / Integration test
├── build.gradle                        # Cấu hình Gradle & dependencies
├── settings.gradle
├── Dockerfile                          # Multi-stage Dockerfile tối ưu
├── .gitignore
├── README.md                           # Tài liệu hướng dẫn & giải thích
└── ssh_deploy_screenshot.png           # Ảnh chụp màn hình log SSH Deploy
```

---

## 3. Cấu hình GitHub Repository Secrets

Để GitHub Actions có thể kết nối an toàn đến VPS, cần khai báo 3 Secrets trong GitHub Repository:
1. Truy cập Repository trên GitHub $\rightarrow$ **Settings** $\rightarrow$ **Secrets and variables** $\rightarrow$ **Actions**.
2. Nhấn **New repository secret** và thêm lần lượt 3 biến:

| Tên Secret | Ý nghĩa | Ví dụ / Hướng dẫn |
| :--- | :--- | :--- |
| `SSH_HOST` | Địa chỉ IP công khai hoặc tên miền của máy chủ VPS | `103.176.179.52` hoặc `vps.example.com` |
| `SSH_USER` | Tên người dùng để đăng nhập SSH vào VPS | `ubuntu` hoặc `root` hoặc `ec2-user` |
| `SSH_KEY` | Toàn bộ nội dung của Private Key SSH (dùng để xác thực không mật khẩu) | Bắt đầu bằng `-----BEGIN OPENSSH PRIVATE KEY-----` (hoặc `-----BEGIN RSA PRIVATE KEY-----`) |

> **Mẹo tạo SSH Key (nếu chưa có)**:
> Trên máy cá nhân hoặc VPS:
> ```bash
> ssh-keygen -t rsa -b 4096 -C "github-actions-deploy" -f ~/.ssh/vps_deploy
> # Thêm public key vào danh sách cho phép trên VPS:
> cat ~/.ssh/vps_deploy.pub >> ~/.ssh/authorized_keys
> chmod 600 ~/.ssh/authorized_keys
> # Copy nội dung file ~/.ssh/vps_deploy (Private Key) để dán vào Secret SSH_KEY trên GitHub.
> ```

---

## 4. Nội dung tệp `.github/workflows/deploy-vps.yml`

```yaml
name: Deploy Spring Boot Container to VPS via SSH

on:
  push:
    branches:
      - main
      - master
  workflow_dispatch:

jobs:
  # ==========================================
  # Job 1: Build & Push Docker Image to GHCR
  # ==========================================
  build-image:
    name: Build & Push Docker Image
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry (GHCR)
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and Push Docker Image
        run: |
          # Chuẩn hóa tên image sang chữ thường (bắt buộc theo chuẩn Docker & GHCR)
          ACTOR_LOWER=$(echo "${{ github.actor }}" | tr '[:upper:]' '[:lower:]')
          IMAGE_URI="ghcr.io/${ACTOR_LOWER}/app:latest"
          
          echo "Building Docker image: ${IMAGE_URI}..."
          docker build -t ${IMAGE_URI} .

          echo "Pushing Docker image to GHCR..."
          docker push ${IMAGE_URI}

  # ==========================================
  # Job 2: Deploy to VPS via SSH Action
  # ==========================================
  deploy-vps:
    name: Deploy to VPS
    runs-on: ubuntu-latest
    needs: build-image
    steps:
      - name: Thực thi câu lệnh triển khai trên VPS qua SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USER }}
          key: ${{ secrets.SSH_KEY }}
          script: |
            echo "=== [1] Đăng nhập GitHub Container Registry trên VPS ==="
            echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

            echo "=== [2] Kéo Image mới nhất từ GHCR ==="
            ACTOR_LOWER=$(echo "${{ github.actor }}" | tr '[:upper:]' '[:lower:]')
            IMAGE_URI="ghcr.io/${ACTOR_LOWER}/app:latest"
            docker pull ${IMAGE_URI}

            echo "=== [3] Khởi chạy lại container ==="
            docker stop app || true
            docker rm app || true
            docker run -d --name app -p 8080:8080 --restart unless-stopped ${IMAGE_URI}

            echo "=== [4] Kiểm tra trạng thái Container sau khi deploy ==="
            docker ps -f name=app
            echo "✅ Container app đã được triển khai thành công trên VPS!"
```

---

## 5. Cấu hình Dockerfile tối ưu (Multi-stage)

```dockerfile
# Stage 1: Build mã nguồn bằng Gradle
FROM eclipse-temurin:17-jdk-alpine AS builder
WORKDIR /app

COPY gradlew .
COPY gradle ./gradle
COPY build.gradle settings.gradle gradle.properties ./

RUN chmod +x gradlew && ./gradlew dependencies --no-daemon || true

COPY src ./src
RUN ./gradlew bootJar -x test --no-daemon

# Stage 2: Runtime image siêu nhẹ
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app

COPY --from=builder /app/build/libs/*.jar app.jar

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java", "-jar", "app.jar"]
```

---

## 6. Kiểm tra & Xác minh sau triển khai

1. **Theo dõi log trên GitHub Actions**:
   * Truy cập tab **Actions** $\rightarrow$ Chọn lần chạy mới nhất của `Deploy Spring Boot Container to VPS via SSH`.
   * Mở Job `deploy-vps` $\rightarrow$ Nhấn vào bước `Thực thi câu lệnh triển khai trên VPS qua SSH`.
   * Kiểm tra các dòng log hiển thị:
     * `Login Succeeded`
     * `docker pull ghcr.io/.../app:latest: Status: Downloaded newer image...`
     * `docker run -d --name app ...`
     * `docker ps -f name=app` hiển thị container `app` đang ở trạng thái `Up X seconds (healthy)`.

2. **Kiểm tra ứng dụng trên trình duyệt / curl**:
   * Kiểm tra Actuator Health Endpoint:
     ```bash
     curl http://<VPS_IP>:8080/actuator/health
     # Kết quả trả về HTTP 200:
     # {"status":"UP"}
     ```
   * Kiểm tra giao diện API:
     ```bash
     curl http://<VPS_IP>:8080/
     # Kết quả trả về HTTP 200:
     # {"status":"UP","message":"Spring Boot Application is running on VPS via SSH Deploy!"}
     ```

---

## 7. Hướng dẫn nộp bài
* **Sản phẩm 1**: Tệp kịch bản `.github/workflows/deploy-vps.yml`.
* **Sản phẩm 2**: Ảnh chụp màn hình log kết quả bước `Thực thi câu lệnh triển khai trên VPS qua SSH` (lưu ảnh vào thư mục `homework/session_12/ex4/ssh_deploy_screenshot.png`).
