// MyInterface - 回调接口定义
// 对应Java: entity/MyInterface.java

// 无参数回调
export type MyFunction = () => void;

// 布尔参数回调
export type MyFunctionBoolean = (bool: boolean) => void;

// 字符串参数回调
export type MyFunctionString = (str: string) => void;

// 整数参数回调
export type MyFunctionInt = (value: number) => void;

// 字节数组参数回调
export type MyFunctionBytes = (buffer: Uint8Array) => void;

// 进度回调
export type MyFunctionProgress = (progress: number) => void;
