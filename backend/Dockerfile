# Stage 1 chche build
FROM golang:1.26-alpine AS deps

# Set the working directory
WORKDIR /app

# Copy go.mod and go.sum to the working directory
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Stage 2: Build the application
FROM deps AS builder

# Set the working directory
WORKDIR /app

ARG CACHE_BUST=1
RUN echo "Cache bust: $CACHE_BUST"

# Copy the entire application source code to the builder stage
COPY . .

# Build the Go application
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w" \
      -o /app/server \
      .
 

# Stage 3: Runtime Reduction
FROM gcr.io/distroless/static:nonroot AS runtime

#Set the working directory
WORKDIR /app

# Copy from builder stage
COPY --from=builder /app/server .

# Use nonroot user to run the application
USER nonroot:nonroot

# Expose the application port
EXPOSE 8080

# Set the entry point to run the application
ENTRYPOINT [ "/app/server" ]
