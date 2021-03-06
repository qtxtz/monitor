#!/bin/bash
#set encoding=utf-8
set -x
#代码规范遵循shellcheck.net的要求
#建议：使用一个非线上账号进行相关的功能验证，会更加安全，这样即使有问题，也不会将系统文件给误删除！！！

#定义的是不同体积的文件，其MD5，作为string写入被测试文件来验证文件内容的正确性
#对于dd确定的命令来说，不同体积的文件，其MD5始终相同
#bs=1MB count=1000 的MD5:  e37115d4da0e187130ab645dee4f14ed
#bs=1MB count=100  的MD5:  0f86d7c5a6180cf9584c1d21144d85b0
#bs=1MB count=10   的MD5:  311175294563b07db7ea80dee2e5b3c6

readonly MD5="0f86d7c5a6180cf9584c1d21144d85b0"
#定义的是命令执行的超时时间
readonly TIMESECsmall="5"
readonly TIMESEClarge="20"
Mountlist=("/disk/cfs-generic-A" "/disk/cfs-generic-B" "/disk/ssd" "/disk/hdd")

#文件名的随机后缀变量
#随机文件有三个目的：
#1）避免删除失败后，始终用过期的旧文件来进行可用性检测，这样没有意义
#2）期望通过随机文件名，能够覆盖更多的datanode，避免单一的固定的文件名被分配到固定的datanode节点
#3）可以满足多节点并行写入不冲突
readonly KEY=$((RANDOM))

#检查输出文件的目录，文件和权限
function check_prometheus
{
    mkdir -p  /var/lib/node_exporter/textfile
    touch /var/lib/node_exporter/textfile/cfs_monitor.prom && chmod 755 /var/lib/node_exporter/textfile/cfs_monitor.prom && echo -n > /var/lib/node_exporter/textfile/cfs_monitor.prom
}

function check_cfs
{ 
    if [ ! -f /usr/bin/nfs-utils ];then
        nohup yum install -y nfs-utils >/dev/null 2>&1
    fi
}

#通过云硬盘写入文件后读取检查云硬盘的可用性
#该部分是测试小文件的可用性，之所以测试小文件的可用性，有两个原因：
#1）场景角度：云硬盘支持操作系统，以及其他小文件场景，因此这类场景是需要覆盖的
#2）被测集群的覆盖率考虑：很多数据节点可能因为存储使用率的关系，无法调度大文件上去，因此使用小文件，能够将一些磁盘使用率较高的机器进行覆盖
#3）避免大小文件分集群，只监控单一场景，则无法保证集群的覆盖率

function check_result
{
    for mountpath in ${Mountlist[@]};do
    
        timeout $TIMESECsmall echo $MD5 > $mountpath/cfs_monitor."$KEY"

        local result=$( timeout $TIMESECsmall cat $mountpath/cfs_monitor."$KEY")

        timeout $TIMESECsmall /usr/bin/rm -f $mountpath/cfs_monitor."$KEY"

        if [ "$result" == "$MD5" ];then
            cd /var/lib/node_exporter/textfile && echo "nfs_monitor_status{path=\"$mountpath\"} 0" >> cfs_monitor.prom
        else
            cd /var/lib/node_exporter/textfile && echo "nfs_monitor_status{path=\"$mountpath\"} 1" >> cfs_monitor.prom
        fi
    done
}

#通过云硬盘写入100MB文件来测试性能，目前测试，通过dd生成固定大小的文件，其md5是相同的，因此在该处只验证了md5，只要md5正确，就输出写入耗时
#写入耗时部分，增加了纳秒统计，否则，无法进行精确比较date +%s%N，如果不需要纳秒级别统计，可以改为date +%s
#需要注意dd命令，添加的conv=fsync，意思是说要确保文件写入到磁盘中，而非操作系统缓存，这个从写入耗时上看也不一样
function check_performance
{
    for mountpath in ${Mountlist[@]};do
        local Begin_time=$(date +%s%N)
        timeout $TIMESEClarge dd if=/dev/zero of=$mountpath/cfs_monitor.performance."$KEY" bs=1MB count=100 conv=fsync 2>/dev/null
        local End_time=$(date +%s%N)
        local time_result=$((End_time - Begin_time))

        if [ "$(md5sum "$mountpath"/cfs_monitor.performance."$KEY" |grep -c $MD5)" -eq 1 ];then
            cd /var/lib/node_exporter/textfile && echo -e "cfs_monitor_100mb{path=\"$mountpath\"} 0\ncfs_monitor_time_100mb{path=\"$mountpath\"} $time_result" >> cfs_monitor.prom
        else
            cd /var/lib/node_exporter/textfile && echo -e "cfs_monitor_100mb{path=\"$mountpath\"} -1\ncfs_monitor_time_100mb{path=\"$mountpath\"} $time_result" >> cfs_monitor.prom
        fi
        timeout $TIMESECsmall /usr/bin/rm -f  "$mountpath"/cfs_monitor.performance."$KEY"
    done
}

function main
{
    check_cfs
    check_prometheus
    check_result
    check_performance
}

main
