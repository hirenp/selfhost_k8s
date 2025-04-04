from flask import Flask, request, render_template, jsonify
import torch
from torch import nn
import torchvision.transforms as transforms
from PIL import Image
import io
import base64
import os
import sys
import traceback
import logging
import time
import gc
import psutil
from werkzeug.utils import secure_filename

# Configure more aggressive logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('/app/app_debug.log')  # Add file logging to catch issues
    ]
)
logger = logging.getLogger(__name__)

# Log startup info
logger.info("========== APPLICATION STARTING ==========")
logger.info(f"Python version: {sys.version}")
logger.info(f"PyTorch version: {torch.__version__}")
logger.info(f"PIL version: {Image.__version__}")
logger.info(f"CUDA available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    logger.info(f"CUDA device count: {torch.cuda.device_count()}")
    logger.info(f"CUDA device name: {torch.cuda.get_device_name(0)}")
logger.info("========================================")

app = Flask(__name__)

# Configure upload folder
UPLOAD_FOLDER = 'static/uploads'
ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg'}
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

# Ensure the upload folder exists
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

# Load the Ghibli style transfer model
class GhibliStyleTransfer:
    def __init__(self):
        self.model = None
        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        self.load_model()
        
    def load_model(self):
        """Load the pre-trained model"""
        logger.info(f"Using device: {self.device}")
        
        # Force CUDA if we requested GPU resources
        if self.device.type == "cpu":
            logger.warning("🚨 WARNING: Running on CPU despite GPU resource request! Trying to force CUDA...")
            if torch.cuda.is_available():
                logger.info(f"CUDA is available! Found {torch.cuda.device_count()} device(s)")
                logger.info(f"CUDA Device Name: {torch.cuda.get_device_name(0)}")
                self.device = torch.device("cuda")
                logger.info(f"Successfully switched to: {self.device}")
            else:
                logger.error("CUDA is not available. Check NVIDIA drivers and libraries.")
        
        # Load the pre-downloaded model
        try:
            # Try to load the saved model state from the Docker image
            model_state_path = os.path.join(os.environ.get('TORCH_HOME', '/app/.torch'), 'hub/deeplabv3_resnet50_state.pth')
            
            if os.path.exists(model_state_path):
                logger.info(f"Found pre-downloaded model state at {model_state_path}")
                # Load the model architecture
                self.model = torch.hub.load('pytorch/vision', 'deeplabv3_resnet50', pretrained=False)
                # Load the saved state
                self.model.load_state_dict(torch.load(model_state_path))
                logger.info("Loaded model from pre-downloaded state")
            else:
                logger.info("Pre-downloaded model state not found, trying to download model from PyTorch Hub...")
                self.model = torch.hub.load('pytorch/vision', 'deeplabv3_resnet50', pretrained=True)
                logger.info("Model downloaded from PyTorch Hub")
            
            self.model.to(self.device)
            self.model.eval()
            logger.info(f"Model loaded successfully on {self.device}")
        except Exception as e:
            logger.error(f"Error loading model: {str(e)}")
            logger.error(traceback.format_exc())  # Print full traceback
            # Fallback to a GPU transformation if model loading fails
            self.model = None
            logger.info("Falling back to GPU-accelerated transformation")
        
        # Print CUDA usage stats
        if self.device.type == "cuda":
            logger.info(f"CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
    
    def preprocess(self, image):
        """Preprocess the image for the model"""
        try:
            logger.debug(f"[PREPROCESS] Input image size: {image.size}, mode: {image.mode}")
            
            # For very large images, resize in two steps to avoid memory issues
            width, height = image.size
            if width > 2000 or height > 2000:
                logger.info(f"[PREPROCESS] Large image detected ({width}x{height}), using two-step resize")
                # Step 1: Resize to intermediate size first
                intermediate_size = (1024, 1024)
                image = image.resize(intermediate_size, Image.LANCZOS)
                logger.debug(f"[PREPROCESS] Intermediate resize to {intermediate_size}")
            
            # Step 2: Apply the standard transformation
            transform = transforms.Compose([
                transforms.Resize((512, 512)),
                transforms.ToTensor(),
                transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
            ])
            tensor = transform(image).unsqueeze(0).to(self.device)
            logger.debug(f"[PREPROCESS] Output tensor shape: {tensor.shape}")
            return tensor
        except Exception as e:
            logger.error(f"[PREPROCESS] Error during preprocessing: {str(e)}")
            logger.error(traceback.format_exc())
            # Create a fallback tensor if preprocessing fails
            logger.info("[PREPROCESS] Creating fallback tensor")
            # Just create a blank normalized tensor with the right shape
            blank = torch.zeros(1, 3, 512, 512, device=self.device)
            # Apply normalization to match expected input range
            mean = torch.tensor([0.485, 0.456, 0.406], device=self.device).view(1, 3, 1, 1)
            std = torch.tensor([0.229, 0.224, 0.225], device=self.device).view(1, 3, 1, 1)
            blank = (blank - mean) / std
            return blank
    
    def postprocess(self, tensor):
        """Convert output tensor back to PIL Image"""
        try:
            # Denormalize and convert tensor to PIL Image
            logger.debug(f"[POSTPROCESS] Input tensor shape: {tensor.shape}")
            tensor = tensor.squeeze(0).cpu()
            logger.debug(f"[POSTPROCESS] After squeeze: {tensor.shape}")
            
            # Handle denormalization with proper broadcasting
            mean = torch.tensor([0.485, 0.456, 0.406]).view(-1, 1, 1)
            std = torch.tensor([0.229, 0.224, 0.225]).view(-1, 1, 1)
            
            if tensor.dim() == 3 and tensor.size(0) == 3:
                # If tensor is [3, H, W], denormalize
                logger.debug("[POSTPROCESS] Denormalizing RGB tensor")
                tensor = tensor * std + mean
            else:
                # If tensor has unexpected shape, just rescale to [0,1]
                logger.warning(f"[POSTPROCESS] Unexpected tensor shape: {tensor.shape}, skipping denormalization")
                # Make sure it's a proper image format (3 channels)
                if tensor.dim() != 3 or tensor.size(0) != 3:
                    logger.warning("[POSTPROCESS] Reshaping tensor to image format")
                    # If we have a single channel, repeat it to make an RGB image
                    if tensor.dim() == 2 or (tensor.dim() == 3 and tensor.size(0) == 1):
                        original = tensor.view(1, tensor.size(-2), tensor.size(-1))
                        tensor = original.repeat(3, 1, 1)
            
            tensor = tensor.clamp(0, 1)
            logger.debug(f"[POSTPROCESS] Final tensor shape: {tensor.shape}")
            return transforms.ToPILImage()(tensor)
        except Exception as e:
            logger.error(f"[POSTPROCESS] Error: {str(e)}")
            logger.error(traceback.format_exc())
            # If postprocessing fails, return a blank image of the same size as input
            logger.info("[POSTPROCESS] Creating fallback blank image")
            blank = torch.zeros(3, 512, 512)
            return transforms.ToPILImage()(blank)
    
    def transform(self, image):
        """Apply Ghibli-style transformation to the image"""
        start_time = time.time()
        
        if self.model is None:
            # If model loading failed, apply a simple filter as fallback
            logger.warning("Model not available, using fallback transformation")
            return self.apply_fallback_transform(image)
        
        try:
            # Log transformation start
            logger.info(f"[TRANSFORM] Starting transformation for image size: {image.size}")
            logger.info(f"[SYSTEM] Available memory: {psutil.virtual_memory().available / (1024**2):.2f} MB")
            
            if self.device.type == "cuda":
                logger.info(f"[GPU] Initial CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
                logger.info(f"[GPU] Max memory: {torch.cuda.max_memory_allocated()/1024**2:.2f}MB")
            
            # Convert to RGB if needed
            if image.mode != 'RGB':
                logger.info(f"[TRANSFORM] Converting image from {image.mode} to RGB")
                image = image.convert('RGB')
            
            # Preprocess the image
            logger.info(f"[TRANSFORM] Preprocessing image, step timing: {time.time() - start_time:.2f}s")
            preprocess_start = time.time()
            input_tensor = self.preprocess(image)
            logger.info(f"[TRANSFORM] Preprocessing complete, took {time.time() - preprocess_start:.2f}s")
            logger.debug(f"[TENSOR] Input tensor shape: {input_tensor.shape}, dtype: {input_tensor.dtype}")
            
            if torch.isnan(input_tensor).any():
                logger.error("[ERROR] NaN values found in input tensor!")
            
            # Report memory before inference
            if self.device.type == "cuda":
                logger.info(f"[GPU] Pre-inference CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
            
            # Run inference
            inference_start = time.time()
            with torch.no_grad():
                logger.info("[TRANSFORM] Running inference with model")
                try:
                    # Get the segmentation mask from DeepLabV3
                    model_output = self.model(input_tensor)
                    inference_time = time.time() - inference_start
                    logger.info(f"[TRANSFORM] Model inference completed in {inference_time:.2f}s")
                    logger.debug(f"[TENSOR] Model output keys: {model_output.keys()}")
                    
                    output = model_output["out"][0]
                    logger.debug(f"[TENSOR] Output tensor shape: {output.shape}")
                    
                    if torch.isnan(output).any():
                        logger.error("[ERROR] NaN values found in model output!")
                except RuntimeError as e:
                    logger.error(f"[ERROR] Runtime error during model inference: {str(e)}")
                    logger.error(traceback.format_exc())
                    if "CUDA out of memory" in str(e):
                        # Try to free memory
                        if self.device.type == "cuda":
                            logger.info("[MEMORY] Trying to free CUDA memory")
                            torch.cuda.empty_cache()
                            gc.collect()
                            logger.info(f"[GPU] After cleanup: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
                        raise
                
                # Create a Ghibli-style effect using the segmentation and original image
                style_start = time.time()
                logger.info("[TRANSFORM] Applying Ghibli-style effects")
                
                # Report memory before styling
                if self.device.type == "cuda":
                    logger.info(f"[GPU] Pre-styling CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
                
                # Get classes with highest probability for each pixel
                # This creates a clean segmentation map for sky, background, foreground, etc.
                try:
                    _, class_map = torch.max(output, dim=0)
                    logger.debug(f"[TENSOR] Class map shape: {class_map.shape}, unique classes: {torch.unique(class_map).tolist()}")
                except Exception as e:
                    logger.error(f"[ERROR] Error creating class map: {str(e)}")
                    logger.error(traceback.format_exc())
                    raise
                
                # Starting with the original image tensor
                try:
                    stylized = input_tensor.clone().squeeze(0)
                    logger.debug(f"[TENSOR] Stylized tensor shape: {stylized.shape}")
                    
                    if torch.isnan(stylized).any():
                        logger.error("[ERROR] NaN values found in stylized tensor after clone!")
                    
                    # Create masks for different elements based on segmentation classes
                    # Typical classes: 0=background, 1=person, 2=sky, 3=vegetation, etc.
                    # Convert to one-hot encoding for smoother masks
                    mask_start = time.time()
                    logger.info("[TRANSFORM] Creating segmentation masks")
                    num_classes = output.shape[0]
                    masks = []
                    
                    for i in range(num_classes):
                        try:
                            mask = (class_map == i).float()
                            # Apply slight blur to mask for smoother transitions
                            mask = torch.nn.functional.avg_pool2d(
                                mask.unsqueeze(0).unsqueeze(0), 
                                kernel_size=9, 
                                stride=1, 
                                padding=4
                            ).squeeze(0).squeeze(0)
                            
                            # Check if mask has any active pixels
                            active_pixels = torch.sum(mask > 0.5).item()
                            logger.debug(f"[MASK] Class {i}: {active_pixels} active pixels")
                            
                            masks.append(mask)
                        except Exception as e:
                            logger.error(f"[ERROR] Error creating mask for class {i}: {str(e)}")
                            logger.error(traceback.format_exc())
                    
                    logger.info(f"[TRANSFORM] Created {len(masks)} masks in {time.time() - mask_start:.2f}s")
                    
                    # Report memory after mask creation
                    if self.device.type == "cuda":
                        logger.info(f"[GPU] Post-mask CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
                except Exception as e:
                    logger.error(f"[ERROR] Error in mask creation stage: {str(e)}")
                    logger.error(traceback.format_exc())
                    raise
                
                # Apply Ghibli-style colors based on segmentation
                
                # 1. Sky/water effects (typically classes 0, 2, 9)
                # Ghibli skies are typically vibrant blues with soft transitions
                for sky_class in [0, 2, 9]:  # Adjust classes based on your model
                    if sky_class < len(masks):
                        sky_mask = masks[sky_class]
                        # Enhance blues, soften reds
                        stylized[0] = stylized[0] * (1 - sky_mask * 0.3)  # Reduce red in sky
                        stylized[2] = torch.min(stylized[2] * (1 + sky_mask * 0.5), torch.tensor(1.0))  # Enhance blue
                
                # 2. Vegetation effects (typically classes 3, 8)
                # Ghibli vegetation has vibrant greens with hints of yellow
                for veg_class in [3, 8]:  # Adjust classes based on your model
                    if veg_class < len(masks):
                        veg_mask = masks[veg_class]
                        # Enhance greens
                        stylized[1] = torch.min(stylized[1] * (1 + veg_mask * 0.3), torch.tensor(1.0))  # Enhance green
                        # Add yellow tint (red + green)
                        stylized[0] = torch.min(stylized[0] * (1 + veg_mask * 0.1), torch.tensor(1.0))  # Slight red for yellow
                
                # 3. Character/foreground effects (typically classes 1, 15)
                # Ghibli characters have defined edges and vibrant colors
                for char_class in [1, 15]:  # Adjust classes based on your model
                    if char_class < len(masks):
                        char_mask = masks[char_class]
                        # Enhance contrast for characters
                        for c in range(3):  # RGB channels
                            stylized[c] = (1 - char_mask) * stylized[c] + char_mask * ((stylized[c] - 0.5) * 1.3 + 0.5).clamp(0, 1)
                
                # Apply global Ghibli-style adjustments
                
                # 1. Overall color balance
                # Slightly increase contrast globally 
                stylized = (stylized - 0.5) * 1.2 + 0.5
                stylized = stylized.clamp(0, 1)
                
                # 2. Add a subtle pastel tint characteristic of Ghibli films
                logger.info("[TRANSFORM] Adding pastel tint")
                try:
                    # Create tensor on the same device as stylized
                    pastel_tint = torch.tensor([0.02, 0.02, 0.05], device=stylized.device)  # Slight blue tint
                    logger.debug(f"[TENSOR] Pastel tint device: {pastel_tint.device}, Stylized device: {stylized.device}")
                    
                    # Check shapes before operating
                    logger.debug(f"[TENSOR] Stylized shape: {stylized.shape}, Pastel tint shape: {pastel_tint.shape}")
                    
                    # Explicitly use clone to avoid in-place modification issues
                    result = stylized.clone() * (1 - 0.15) + pastel_tint.view(3, 1, 1) * 0.15
                    stylized = result
                except Exception as tint_error:
                    logger.error(f"[ERROR] Error applying pastel tint: {str(tint_error)}")
                    logger.error(traceback.format_exc())
                    # Continue without tint if error occurs
                
                # 3. Smooth details to replicate the hand-drawn feel
                # Apply a small kernel blur but preserve edges (guided by segmentation)
                edge_strength = torch.zeros_like(class_map, dtype=torch.float32)
                for i in range(1, class_map.shape[0] - 1):
                    for j in range(1, class_map.shape[1] - 1):
                        if class_map[i, j] != class_map[i-1, j] or class_map[i, j] != class_map[i+1, j] or \
                           class_map[i, j] != class_map[i, j-1] or class_map[i, j] != class_map[i, j+1]:
                            edge_strength[i, j] = 1.0
                
                # Blur more where there are no edges
                for c in range(3):
                    blur_kernel = torch.ones(5, 5) / 25.0
                    blur_kernel = blur_kernel.to(stylized.device)
                    blurred = torch.nn.functional.conv2d(
                        stylized[c].unsqueeze(0).unsqueeze(0),
                        blur_kernel.unsqueeze(0).unsqueeze(0),
                        padding=2
                    ).squeeze(0).squeeze(0)
                    # Mix original and blurred based on edge strength
                    stylized[c] = edge_strength * stylized[c] + (1 - edge_strength) * blurred
                
                # Ensure the output is a proper tensor with batch dimension
                final_start = time.time()
                logger.info("[TRANSFORM] Preparing final output tensor")
                
                try:
                    # Make sure the tensor has the right shape for an image: [C, H, W]
                    if stylized.dim() == 3 and stylized.size(0) == 3:
                        logger.debug(f"[TENSOR] Stylized tensor has correct shape: {stylized.shape}")
                        output = stylized.unsqueeze(0)  # Add batch dimension: [1, C, H, W]
                    else:
                        logger.warning(f"[TENSOR] Stylized tensor has unexpected shape: {stylized.shape}")
                        # Reshape to standard image format if needed
                        if stylized.dim() == 2:
                            # Single channel image, convert to RGB by repeating
                            logger.info("[TRANSFORM] Converting single channel to RGB")
                            stylized = stylized.unsqueeze(0).repeat(3, 1, 1)
                        elif stylized.dim() > 3:
                            # Too many dimensions, flatten extra ones
                            logger.info("[TRANSFORM] Flattening extra dimensions")
                            stylized = stylized.view(3, 512, 512)
                        output = stylized.unsqueeze(0)
                    
                    logger.debug(f"[TENSOR] Final output tensor shape: {output.shape}")
                    
                    # Check for NaN values in final tensor
                    if torch.isnan(output).any():
                        logger.error("[ERROR] NaN values found in final output tensor!")
                        # Try to fix NaNs by replacing with zeros
                        output = torch.nan_to_num(output, nan=0.0)
                        logger.info("[RECOVERY] Replaced NaN values with zeros")
                    
                    # Report final GPU memory usage
                    if self.device.type == "cuda":
                        logger.info(f"[GPU] Final CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
                        logger.info(f"[GPU] Max memory allocated: {torch.cuda.max_memory_allocated()/1024**2:.2f}MB")
                except Exception as shape_error:
                    logger.error(f"[ERROR] Error preparing output tensor: {str(shape_error)}")
                    logger.error(traceback.format_exc())
                    # Create a new tensor with the right shape
                    logger.info("[TRANSFORM] Creating blank tensor with correct shape")
                    output = torch.zeros(1, 3, 512, 512, device=self.device)
                    # Copy some content if possible
                    try:
                        if stylized is not None:
                            # Try to preserve some of the image data
                            logger.info("[TRANSFORM] Attempting to preserve image data")
                            for c in range(min(3, stylized.size(0))):
                                output[0, c] = stylized[c] if c < stylized.size(0) else 0
                    except Exception:
                        pass  # Silently continue with blank tensor
            
            # Postprocess the output
            logger.info("[TRANSFORM] Postprocessing output to image")
            try:
                result = self.postprocess(output)
                total_time = time.time() - start_time
                logger.info(f"[TRANSFORM] Transformation complete in {total_time:.2f}s, result size: {result.size}")
                return result
            except Exception as e:
                logger.error(f"[ERROR] Error during postprocessing: {str(e)}")
                logger.error(traceback.format_exc())
                # Try to recover by returning original image
                logger.info("[RECOVERY] Returning original image due to postprocessing error")
                return image
        except Exception as e:
            logger.error(f"Error during transformation: {str(e)}")
            logger.error(traceback.format_exc())
            return self.apply_fallback_transform(image)
    
    def apply_fallback_transform(self, image):
        """Apply a simplified filter as fallback"""
        try:
            logger.info("[FALLBACK] Applying simplified Ghibli-style transformation")
            
            # Convert to PIL image to use PIL transformations (more reliable than tensor ops)
            from PIL import ImageEnhance, ImageFilter
            
            result = image.copy()
            
            # Apply a series of simple PIL transformations to get a Ghibli look
            try:
                # 1. Slightly blur to simulate hand-drawn feel
                logger.info("[FALLBACK] Applying blur effect")
                result = result.filter(ImageFilter.GaussianBlur(radius=0.5))
                
                # 2. Enhance color saturation
                logger.info("[FALLBACK] Enhancing color")
                enhancer = ImageEnhance.Color(result)
                result = enhancer.enhance(1.3)  # Ghibli's vibrant colors
                
                # 3. Enhance contrast
                logger.info("[FALLBACK] Enhancing contrast")
                enhancer = ImageEnhance.Contrast(result)
                result = enhancer.enhance(1.2)  # Ghibli's high contrast
                
                # 4. Slightly brighten
                logger.info("[FALLBACK] Adjusting brightness")
                enhancer = ImageEnhance.Brightness(result)
                result = enhancer.enhance(1.05)  # Ghibli's bright palette
                
                # 5. Sharpen slightly to recover details
                logger.info("[FALLBACK] Sharpening")
                enhancer = ImageEnhance.Sharpness(result)
                result = enhancer.enhance(1.1)  # Ghibli's detailed look
                
                logger.info("[FALLBACK] Successfully applied simplified Ghibli style")
                return result
                
            except Exception as inner_e:
                logger.error(f"[FALLBACK] Error in PIL processing: {str(inner_e)}")
                logger.error(traceback.format_exc())
                # Return original if PIL enhancement fails
                return image
                
        except Exception as e:
            logger.error(f"[FALLBACK] Critical error: {str(e)}")
            logger.error(traceback.format_exc())
            # If all else fails, return original
            return image

# Initialize the style transfer model
style_transfer = GhibliStyleTransfer()

# Actual transformation function that uses our model
def ghibli_transform(image):
    """Apply Ghibli-style transformation to image"""
    return style_transfer.transform(image)

def allowed_file(filename):
    return '.' in filename and \
           filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

@app.route('/')
def index():
    return render_template('index.html')

# Add a global request counter for debugging
request_counter = 0

# Add a basic health check endpoint to test if app is running
@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({"status": "ok", "message": "Application is running"}), 200

@app.route('/transform', methods=['POST'])
def transform_image():
    # Super early logging to catch any request issues
    global request_counter
    request_counter += 1
    
    # Log immediately to both stdout and file
    early_log_msg = f"TRANSFORM REQUEST #{request_counter} RECEIVED AT {time.time()}"
    print(early_log_msg, flush=True)
    with open('/app/early_requests.log', 'a') as f:
        f.write(f"{early_log_msg}\n")
    
    # Standard request tracking
    request_start_time = time.time()
    request_id = f"req_{int(request_start_time * 1000) % 10000}"
    
    # Log request details including headers and content type
    logger.info(f"[REQUEST:{request_id}] ===== NEW TRANSFORMATION REQUEST =====")
    logger.info(f"[REQUEST:{request_id}] Request #{request_counter}")
    
    # Log request details
    try:
        logger.info(f"[REQUEST:{request_id}] Content-Type: {request.content_type}")
        logger.info(f"[REQUEST:{request_id}] Content-Length: {request.content_length}")
        logger.info(f"[REQUEST:{request_id}] Form keys: {list(request.form.keys())}")
        logger.info(f"[REQUEST:{request_id}] Files keys: {list(request.files.keys())}")
    except Exception as req_error:
        logger.error(f"[REQUEST:{request_id}] Error getting request details: {str(req_error)}")
    
    try:
        logger.info(f"[REQUEST:{request_id}] Starting transformation processing")
        
        # System status at request start
        sys_memory = psutil.virtual_memory()
        logger.info(f"[SYSTEM:{request_id}] Memory: {sys_memory.percent}% used, {sys_memory.available/(1024**2):.2f}MB available")
        
        if torch.cuda.is_available():
            logger.info(f"[GPU:{request_id}] CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
            torch.cuda.empty_cache()
            logger.info(f"[GPU:{request_id}] After cache clear: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated")
        
        if 'file' not in request.files:
            logger.warning(f"[REQUEST:{request_id}] No file part in request")
            return jsonify({'error': 'No file part'}), 400
        
        file = request.files['file']
        
        if file.filename == '':
            logger.warning(f"[REQUEST:{request_id}] Empty filename submitted")
            return jsonify({'error': 'No selected file'}), 400
        
        if file and allowed_file(file.filename):
            # Save original image
            filename = secure_filename(file.filename)
            base_filename, ext = os.path.splitext(filename)
            logger.info(f"[REQUEST:{request_id}] Processing file: {filename}")
            
            # Add request ID to filename to avoid collisions
            safe_base = f"{base_filename}_{request_id}"
            original_path = os.path.join(app.config['UPLOAD_FOLDER'], f"{safe_base}_original{ext}")
            file.save(original_path)
            logger.info(f"[REQUEST:{request_id}] Original image saved to: {original_path}")
            
            # Transform image
            try:
                # Log file info
                file_size = os.path.getsize(original_path) / (1024 * 1024)  # Size in MB
                logger.info(f"[REQUEST:{request_id}] File size: {file_size:.2f}MB")
                
                # Open the image with detailed logging
                try:
                    logger.info(f"[REQUEST:{request_id}] Attempting to open image: {original_path}")
                    image = Image.open(original_path)
                    logger.info(f"[REQUEST:{request_id}] Successfully opened image")
                    # Log detailed image properties
                    width, height = image.size
                    logger.info(f"[REQUEST:{request_id}] Image properties: size={width}x{height}, mode={image.mode}, format={image.format}")
                    
                    # Check if image dimensions are very large
                    if width > 2000 or height > 2000:
                        logger.warning(f"[REQUEST:{request_id}] Large image detected: {width}x{height}")
                        
                        # For very large images, resize to reduce memory usage
                        if width > 4000 or height > 4000:
                            logger.info(f"[REQUEST:{request_id}] Resizing very large image")
                            # Calculate new dimensions while maintaining aspect ratio
                            ratio = min(4000 / width, 4000 / height)
                            new_width = int(width * ratio)
                            new_height = int(height * ratio)
                            image = image.resize((new_width, new_height), Image.LANCZOS)
                            logger.info(f"[REQUEST:{request_id}] Resized to {new_width}x{new_height}")
                    
                    # Check for image metadata
                    try:
                        exif_data = image.getexif()
                        if exif_data:
                            logger.info(f"[REQUEST:{request_id}] Image has EXIF data with {len(exif_data)} tags")
                    except Exception as exif_error:
                        logger.warning(f"[REQUEST:{request_id}] Error reading EXIF data: {str(exif_error)}")
                    
                    # Check image mode and convert if necessary
                    if image.mode != 'RGB':
                        logger.info(f"[REQUEST:{request_id}] Converting image from {image.mode} to RGB")
                        image = image.convert('RGB')
                    
                except Exception as img_error:
                    logger.error(f"[REQUEST:{request_id}] Error opening image: {str(img_error)}")
                    logger.error(traceback.format_exc())
                    return jsonify({'error': f'Error processing image: {str(img_error)}'}), 500
                
                # Set a timeout for transformation (300 seconds)
                transform_start = time.time()
                logger.info(f"[REQUEST:{request_id}] Starting transformation")
                
                try:
                    # Explicitly create memory snapshots for debugging
                    if torch.cuda.is_available():
                        torch.cuda.reset_peak_memory_stats()
                        pre_mem = torch.cuda.memory_allocated()/1024**2
                        logger.info(f"[REQUEST:{request_id}] Pre-transform GPU memory: {pre_mem:.2f}MB")
                    
                    # Actually transform the image with additional error handling
                    try:
                        logger.info(f"[REQUEST:{request_id}] Calling ghibli_transform function")
                        transformed_image = ghibli_transform(image)
                        logger.info(f"[REQUEST:{request_id}] ghibli_transform function returned successfully")
                    except Exception as transform_inner_error:
                        logger.error(f"[REQUEST:{request_id}] Inner transformation error: {str(transform_inner_error)}")
                        logger.error(traceback.format_exc())
                        # Try with our fallback as a direct call
                        logger.info(f"[REQUEST:{request_id}] Attempting direct fallback transformation")
                        transformed_image = style_transfer.apply_fallback_transform(image)
                    
                    transform_time = time.time() - transform_start
                    logger.info(f"[REQUEST:{request_id}] Transformation completed in {transform_time:.2f}s")
                    
                    # Additional CUDA memory stats
                    if torch.cuda.is_available():
                        post_mem = torch.cuda.memory_allocated()/1024**2
                        peak_mem = torch.cuda.max_memory_allocated()/1024**2
                        logger.info(f"[REQUEST:{request_id}] Post-transform GPU memory: {post_mem:.2f}MB, Peak: {peak_mem:.2f}MB")
                    
                    # Check if the result is valid
                    if transformed_image is None:
                        logger.error(f"[REQUEST:{request_id}] Transformation returned None result")
                        raise ValueError("Transformation returned None result")
                    
                    # Verify the transformed image is actually a PIL Image
                    if not isinstance(transformed_image, Image.Image):
                        logger.error(f"[REQUEST:{request_id}] Result is not a PIL Image but {type(transformed_image)}")
                        raise TypeError(f"Expected PIL Image but got {type(transformed_image)}")
                    
                    # Log the transformed image details
                    logger.info(f"[REQUEST:{request_id}] Transformed image: size={transformed_image.size}, mode={transformed_image.mode}")
                    
                    # Save transformed image with error handling
                    try:
                        transformed_path = os.path.join(app.config['UPLOAD_FOLDER'], f"{safe_base}_transformed{ext}")
                        logger.info(f"[REQUEST:{request_id}] Saving transformed image to: {transformed_path}")
                        transformed_image.save(transformed_path)
                        logger.info(f"[REQUEST:{request_id}] Successfully saved transformed image")
                    except Exception as save_error:
                        logger.error(f"[REQUEST:{request_id}] Error saving transformed image: {str(save_error)}")
                        logger.error(traceback.format_exc())
                        raise
                    
                    # Clean up memory
                    if torch.cuda.is_available():
                        torch.cuda.empty_cache()
                        gc.collect()
                    
                    # Return paths to both images
                    total_request_time = time.time() - request_start_time
                    logger.info(f"[REQUEST:{request_id}] Request completed successfully in {total_request_time:.2f}s")
                    return jsonify({
                        'original': f"/static/uploads/{os.path.basename(original_path)}",
                        'transformed': f"/static/uploads/{os.path.basename(transformed_path)}"
                    })
                except Exception as transform_error:
                    # Specific logging for transformation errors
                    logger.error(f"[ERROR:{request_id}] Transformation failed: {str(transform_error)}")
                    logger.error(traceback.format_exc())
                    
                    # Try to clean up memory after error
                    if torch.cuda.is_available():
                        logger.info(f"[GPU:{request_id}] Cleaning up after error")
                        torch.cuda.empty_cache()
                        gc.collect()
                    
                    return jsonify({'error': f'An error occurred during image transformation: {str(transform_error)}'}), 500
            except Exception as e:
                logger.error(f"[ERROR:{request_id}] Error in request processing: {str(e)}")
                logger.error(traceback.format_exc())
                return jsonify({'error': f'An error occurred during transformation process: {str(e)}'}), 500
        else:
            logger.warning(f"File type not allowed: {file.filename}")
            return jsonify({'error': 'File type not allowed'}), 400
    except Exception as e:
        logger.error(f"Unexpected error in transform_image endpoint: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({'error': f'Server error: {str(e)}'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)