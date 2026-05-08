import re
import numpy as np

def parse_vhd_weights(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    def extract_matrix(var_name, shape):
        pattern = rf"constant {var_name}.*?\(.*?\) := \((.*?)\);"
        match = re.search(pattern, content, re.DOTALL | re.IGNORECASE)
        if not match:
            print(f"Matrix {var_name} not found!")
            return np.zeros(shape)
        
        matrix_str = match.group(1)
        matrix = np.zeros(shape, dtype=np.int32)
        
        row_matches = re.finditer(r"(\d+) => \((.*?)\)", matrix_str)
        for r_match in row_matches:
            r = int(r_match.group(1))
            cols_str = r_match.group(2)
            col_matches = re.finditer(r"(\d+) => (-?\d+)", cols_str)
            for c_match in col_matches:
                c = int(c_match.group(1))
                val = int(c_match.group(2))
                matrix[r, c] = val
        return matrix

    def extract_vector(var_name, length):
        pattern = rf"constant {var_name}.*?\(.*?\) := \((.*?)\);"
        match = re.search(pattern, content, re.DOTALL | re.IGNORECASE)
        if not match:
            print(f"Vector {var_name} not found!")
            return np.zeros(length)
        
        vec_str = match.group(1)
        # It's a simple list of comma-separated numbers
        nums = [int(x.strip()) for x in vec_str.split(',')]
        return np.array(nums, dtype=np.int32)
    
    W_INPUT_HIDDEN = extract_matrix("W_INPUT_HIDDEN", (64, 256))
    W_HIDDEN_OUTPUT = extract_matrix("W_HIDDEN_OUTPUT", (10, 64))
    
    B_INPUT_HIDDEN = extract_vector("B_INPUT_HIDDEN", 64)
    B_HIDDEN_OUTPUT = extract_vector("B_HIDDEN_OUTPUT", 10)
    
    return W_INPUT_HIDDEN, W_HIDDEN_OUTPUT, B_INPUT_HIDDEN, B_HIDDEN_OUTPUT

if __name__ == "__main__":
    w1, w2, b1, b2 = parse_vhd_weights('/tmp/SNN-FPGA/Python scripts/weights_pkg.vhd')
    np.savez('snn_weights.npz', w1=w1, w2=w2, b1=b1, b2=b2)
    print("Saved snn_weights.npz")
    print(w1.shape, w2.shape, b1.shape, b2.shape)
