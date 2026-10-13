# Multi-stage build for Spring Boot application
FROM eclipse-temurin:17-jdk-alpine AS builder
WORKDIR /app

# Copy gradle wrapper and configs first for caching
COPY gradlew .
COPY gradle ./gradle
COPY build.gradle settings.gradle gradle.properties ./

# Grant execution rights and pre-cache dependencies
RUN chmod +x gradlew && ./gradlew dependencies --no-daemon || true

# Copy source code and build runnable jar
COPY src ./src
RUN ./gradlew bootJar -x test --no-daemon

# Runtime Stage
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app

# Copy jar from builder stage
COPY --from=builder /app/build/libs/*.jar app.jar

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java", "-jar", "app.jar"]
