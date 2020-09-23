rm -rf buck-out
find . -name "*.xcodeproj" | xargs  rm -rf
find . -name "*.xcworkspace" | xargs  rm -rf
echo '删除成功'
buck clean