# ---------- Stage 1: Build the application --------------
FROM nginx:alpine AS builder

# Set the working directory
WORKDIR /app

ARG CACHE_BUST=1
RUN echo "Cache bust: $CACHE_BUST"

# Copy the application files to the builder stage
COPY index.html .
COPY css ./css
COPY js ./js

# -----   Stage 2: Serve the application with Nginx --------

FROM nginx:alpine

# Remove default nginx config and default HTML
RUN rm -rf /usr/share/nginx/html/* \
    && rm /etc/nginx/conf.d/default.conf

# Copy built files from the builder stage

COPY --from=builder /app /usr/share/nginx/html

# Copy nginx configuration file

COPY nginx.conf /etc/nginx/conf.d/default.conf

# Expose port 8080

EXPOSE 80
