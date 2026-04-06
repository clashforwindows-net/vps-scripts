#!/bin/bash
# Docker 容器管理工具
# https://github.com/vpsvip-net/vps-zi-dong-hua

echo "=========================================="
echo "       Docker 容器管理工具"
echo "=========================================="

case "$1" in
    start)
        echo "启动所有容器..."
        docker-compose up -d
        ;;
    stop)
        echo "停止所有容器..."
        docker-compose down
        ;;
    restart)
        echo "重启所有容器..."
        docker-compose restart
        ;;
    status)
        echo "容器状态:"
        docker ps -a
        ;;
    logs)
        echo "容器日志:"
        docker-compose logs --tail=50
        ;;
    clean)
        echo "清理中..."
        docker system prune -af
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status|logs|clean}"
        exit 1
        ;;
esac
