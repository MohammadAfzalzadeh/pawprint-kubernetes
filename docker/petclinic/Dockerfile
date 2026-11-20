ARG BUILD_BASE=docker-mirror.liara.ir/eclipse-temurin:17-jdk-jammy@sha256:76751c16a2a07ec0960e659a2603491f8c79d95592173f6c0df8bf8ebab257cc
ARG RUN_BASE=docker-mirror.liara.ir/eclipse-temurin:17-jre-jammy@sha256:aa6381384f8db99762fa7d0d3c2b5de58874e5f12c96df4c13a1455376ae0ed1
FROM ${BUILD_BASE} AS build
WORKDIR /build
COPY spring-petclinic/.mvn/ .mvn/
COPY spring-petclinic/mvnw spring-petclinic/pom.xml ./
COPY spring-petclinic/src/ src/
RUN --mount=type=cache,target=/root/.m2 chmod +x mvnw && \
    MAVEN_OPTS="-Xmx384m -XX:ActiveProcessorCount=2" ./mvnw -B -ntp -DskipTests package && \
    cp target/spring-petclinic-*.jar /petclinic.jar

FROM ${RUN_BASE}
WORKDIR /app
COPY --from=build --chown=10001:10001 /petclinic.jar ./petclinic.jar
USER 10001:10001
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=55 -XX:ActiveProcessorCount=2 -XX:+ExitOnOutOfMemoryError" \
    MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health \
    MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true \
    SERVER_SHUTDOWN=graceful
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s CMD curl -fsS "http://127.0.0.1:${MANAGEMENT_SERVER_PORT:-8080}/actuator/health/liveness" || exit 1
ENTRYPOINT ["java", "-jar", "/app/petclinic.jar"]
