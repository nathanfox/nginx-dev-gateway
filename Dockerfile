FROM nginx:1.25-alpine

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    gettext \
    nss-tools \
    ca-certificates

# Create nginx user and directories with proper permissions
RUN mkdir -p /var/cache/nginx /var/log/nginx /etc/nginx/conf.d /tmp/nginx \
    && chown -R nginx:nginx /var/cache/nginx /var/log/nginx /tmp/nginx

# Copy nginx configuration templates as root first
COPY --chown=nginx:nginx nginx/nginx.conf.template /etc/nginx/nginx.conf.template
COPY --chown=nginx:nginx nginx/conf.d/ /etc/nginx/conf.d/
COPY --chown=nginx:nginx nginx/includes/ /etc/nginx/includes/

# Copy entrypoint script with nginx ownership
COPY --chown=nginx:nginx nginx/scripts/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Create directory for ConfigMap volume mount and fix all permissions
RUN mkdir -p /etc/nginx/routes /run/nginx \
    && chown -R nginx:nginx /etc/nginx /run/nginx \
    && chmod -R 755 /etc/nginx \
    && chmod 777 /tmp

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Expose port
EXPOSE 80

# Set working directory
WORKDIR /etc/nginx

# Run as non-root nginx user
USER nginx

# Set entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]