# ------------------------------------------------------
# Production-ready Dockerfile for static Vite/React dist
# ------------------------------------------------------

# Use lightweight Nginx to serve static files
FROM nginx:stable-alpine

# Clean default nginx HTML
RUN rm -rf /usr/share/nginx/html/*

# Copy the dist folder from the repo into the Nginx web directory
COPY dist/ /usr/share/nginx/html/

# Copy a custom nginx configuration (optional, but recommended for SPA)
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Expose port 80 inside container
EXPOSE 80

# Start nginx in foreground
CMD ["nginx", "-g", "daemon off;"]
