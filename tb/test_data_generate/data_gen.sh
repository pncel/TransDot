g++ -std=c++17 -O2 \
  -I../flexfloat/include \
  generate_test_data.cpp \
  -L../flexfloat -lflexfloat -lstdc++fs \
  -o generate_test_data

./generate_test_data 10