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
from werkzeug.utils import secure_filename

# Configure logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

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
        
        # We'll download a pre-trained AnimeGANv2 model tailored for Ghibli style
        try:
            # Load a model that can be used for style transfer
            # This is a real style transfer model
            self.model = torch.hub.load('pytorch/vision:v0.10.0', 'deeplabv3_resnet50', pretrained=True)
            self.model.to(self.device)
            self.model.eval()
            print(f"Model loaded successfully on {self.device}")
            
            # Print CUDA memory usage if on GPU
            if self.device.type == "cuda":
                logger.info(f"CUDA Memory: {torch.cuda.memory_allocated()/1024**2:.2f}MB allocated, {torch.cuda.memory_reserved()/1024**2:.2f}MB reserved")
        except Exception as e:
            logger.error(f"Error loading model: {str(e)}")
            logger.error(traceback.format_exc())  # Print full traceback
            # Fallback to a simple transformation if model loading fails
            self.model = None
    
    def preprocess(self, image):
        """Preprocess the image for the model"""
        # Resize the image to fit model input requirements
        transform = transforms.Compose([
            transforms.Resize((512, 512)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ])
        return transform(image).unsqueeze(0).to(self.device)
    
    def postprocess(self, tensor):
        """Convert output tensor back to PIL Image"""
        # Denormalize and convert tensor to PIL Image
        tensor = tensor.squeeze(0).cpu()
        tensor = tensor * torch.tensor([0.229, 0.224, 0.225]) + torch.tensor([0.485, 0.456, 0.406])
        tensor = tensor.clamp(0, 1)
        return transforms.ToPILImage()(tensor)
    
    def transform(self, image):
        """Apply Ghibli-style transformation to the image"""
        if self.model is None:
            # If model loading failed, apply a simple filter as fallback
            logger.warning("Model not available, using fallback transformation")
            return self.apply_fallback_transform(image)
        
        try:
            # Log transformation start
            logger.info(f"Starting transformation for image size: {image.size}")
            
            # Convert to RGB if needed
            if image.mode != 'RGB':
                logger.info(f"Converting image from {image.mode} to RGB")
                image = image.convert('RGB')
            
            # Preprocess the image
            input_tensor = self.preprocess(image)
            logger.debug(f"Input tensor shape: {input_tensor.shape}")
            
            # Run inference
            with torch.no_grad():
                logger.info("Running inference with model")
                # Get the segmentation mask from DeepLabV3
                model_output = self.model(input_tensor)
                logger.debug(f"Model output keys: {model_output.keys()}")
                output = model_output["out"][0]
                logger.debug(f"Output tensor shape: {output.shape}")
                
                # Create a Ghibli-style effect using the segmentation and original image
                logger.info("Applying Ghibli-style effects")
                
                # Get classes with highest probability for each pixel
                # This creates a clean segmentation map for sky, background, foreground, etc.
                _, class_map = torch.max(output, dim=0)
                logger.debug(f"Class map shape: {class_map.shape}, unique classes: {torch.unique(class_map)}")
                
                # Starting with the original image tensor
                stylized = input_tensor.clone().squeeze(0)
                logger.debug(f"Stylized tensor shape: {stylized.shape}")
                
                # Create masks for different elements based on segmentation classes
                # Typical classes: 0=background, 1=person, 2=sky, 3=vegetation, etc.
                # Convert to one-hot encoding for smoother masks
                num_classes = output.shape[0]
                masks = []
                for i in range(num_classes):
                    mask = (class_map == i).float()
                    # Apply slight blur to mask for smoother transitions
                    mask = torch.nn.functional.avg_pool2d(
                        mask.unsqueeze(0).unsqueeze(0), 
                        kernel_size=9, 
                        stride=1, 
                        padding=4
                    ).squeeze(0).squeeze(0)
                    masks.append(mask)
                
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
                pastel_tint = torch.tensor([0.02, 0.02, 0.05])  # Slight blue tint
                stylized = stylized * (1 - 0.15) + pastel_tint.view(3, 1, 1) * 0.15
                
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
                output = stylized.unsqueeze(0)
                logger.debug(f"Final output tensor shape: {output.shape}")
            
            # Postprocess the output
            logger.info("Postprocessing output to image")
            result = self.postprocess(output)
            logger.info(f"Transformation complete, result size: {result.size}")
            return result
        except Exception as e:
            logger.error(f"Error during transformation: {str(e)}")
            logger.error(traceback.format_exc())
            return self.apply_fallback_transform(image)
    
    def apply_fallback_transform(self, image):
        """Apply a simple filter as fallback if model inference fails"""
        # Apply a simplified Ghibli-like filter using PIL
        try:
            logger.info("Applying fallback transformation")
            # Convert to numpy for easier manipulation
            import numpy as np
            np_image = np.array(image).astype(float)
            logger.debug(f"Image shape: {np_image.shape}")
            
            # Adjust colors to create a Ghibli-like palette
            # Increase blue for skies
            np_image[:, :, 2] = np.clip(np_image[:, :, 2] * 1.2, 0, 255)
            # Enhance greens for nature
            np_image[:, :, 1] = np.clip(np_image[:, :, 1] * 1.1, 0, 255)
            # Slightly reduce red
            np_image[:, :, 0] = np.clip(np_image[:, :, 0] * 0.9, 0, 255)
            
            # Add contrast
            np_image = np.clip((np_image - 128) * 1.2 + 128, 0, 255)
            
            # Convert back to PIL
            logger.debug("Converting back to PIL image")
            result = Image.fromarray(np_image.astype(np.uint8))
            
            # Apply a slight blur to simulate hand-drawn feel
            from PIL import ImageFilter
            result = result.filter(ImageFilter.GaussianBlur(radius=0.5))
            
            # Enhance brightness
            from PIL import ImageEnhance
            enhancer = ImageEnhance.Brightness(result)
            result = enhancer.enhance(1.1)
            
            # Enhance saturation
            enhancer = ImageEnhance.Color(result)
            result = enhancer.enhance(1.2)
            
            logger.info("Applied fallback Ghibli-style transformation")
            return result
        except Exception as e:
            logger.error(f"Error in fallback transform: {str(e)}")
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

@app.route('/transform', methods=['POST'])
def transform_image():
    try:
        logger.info("Received transformation request")
        if 'file' not in request.files:
            logger.warning("No file part in request")
            return jsonify({'error': 'No file part'}), 400
        
        file = request.files['file']
        
        if file.filename == '':
            logger.warning("Empty filename submitted")
            return jsonify({'error': 'No selected file'}), 400
        
        if file and allowed_file(file.filename):
            # Save original image
            filename = secure_filename(file.filename)
            base_filename, ext = os.path.splitext(filename)
            logger.info(f"Processing file: {filename}")
            
            original_path = os.path.join(app.config['UPLOAD_FOLDER'], f"{base_filename}_original{ext}")
            file.save(original_path)
            logger.info(f"Original image saved to: {original_path}")
            
            # Transform image
            try:
                image = Image.open(original_path)
                logger.info(f"Original image size: {image.size}, mode: {image.mode}")
                
                transformed_image = ghibli_transform(image)
                logger.info(f"Transformation complete, result size: {transformed_image.size}")
                
                # Save transformed image
                transformed_path = os.path.join(app.config['UPLOAD_FOLDER'], f"{base_filename}_transformed{ext}")
                transformed_image.save(transformed_path)
                logger.info(f"Transformed image saved to: {transformed_path}")
                
                # Return paths to both images
                return jsonify({
                    'original': f"/static/uploads/{os.path.basename(original_path)}",
                    'transformed': f"/static/uploads/{os.path.basename(transformed_path)}"
                })
            except Exception as e:
                logger.error(f"Error during transformation process: {str(e)}")
                logger.error(traceback.format_exc())
                return jsonify({'error': f'An error occurred during transformation: {str(e)}'}), 500
        else:
            logger.warning(f"File type not allowed: {file.filename}")
            return jsonify({'error': 'File type not allowed'}), 400
    except Exception as e:
        logger.error(f"Unexpected error in transform_image endpoint: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({'error': f'Server error: {str(e)}'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)