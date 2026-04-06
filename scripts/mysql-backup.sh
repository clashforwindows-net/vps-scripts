#!/bin/bash
# MySQL 数据库备份脚本
# https://github.com/vpsvip-net/vps-zi-dong-hua

BACKUP_DIR="/var/backups/mysql"
DB_USER="root"
DB_PASS="your_password"
DB_NAME="your_database"
REMOTE="backup"

mkdir -p "${BACKUP_DIR}"

echo "正在备份 MySQL 数据库: ${DB_NAME}"
mysqldump -u "${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" | gzip > "${BACKUP_DIR}/${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql.gz"

# 只保留最近7天
find "${BACKUP_DIR}" -name "*.gz" -mtime +7 -delete

# 上传到云端
rclone copy "${BACKUP_DIR}" "${REMOTE}:mysql-backups/" --quiet

echo "备份完成!"
