//
//  CVHelper.m
//  test
//
//  Created by re on 2020/2/17.
//  Copyright © 2020 weirme. All rights reserved.
//


#import <opencv2/opencv.hpp>
#import <opencv2/imgcodecs/ios.h>

#include <iostream>
#include <vector>
#include <string>
#include <sstream>
#include <cassert>
#include <algorithm>

#import "CVHelper.h"
#import "../TorchBridge/DEXTR.h"

#define PAD 50
#define THRES 0.8
#define RESIZE 512

const std::string DEXTR_PATH = [[NSBundle mainBundle] pathForResource:@"dextr" ofType:@"pt"].UTF8String;


static void split(const std::string& s, std::vector<int>& sv, const char delim=' ') {
    sv.clear();
    std::istringstream iss(s);
    std::string temp;

    while (std::getline(iss, temp, delim)) {
        sv.push_back(std::stoi(temp));
    }

    return;
}


static std::vector<int> getBbox(UIImage* image, std::vector<int> xcoords, std::vector<int> ycoords, int pad) {
    int xminBound = 0;
    int yminBound = 0;
    int xmaxBound = image.size.width - 1;
    int ymaxBound = image.size.height - 1;
    
    int xmin = std::max(*std::min_element(xcoords.begin(), xcoords.end()) - pad, xminBound);
    int ymin = std::max(*std::min_element(ycoords.begin(), ycoords.end()) - pad, yminBound);
    int xmax = std::min(*std::max_element(xcoords.begin(), xcoords.end()) + pad, xmaxBound);
    int ymax = std::min(*std::max_element(ycoords.begin(), ycoords.end()) + pad, ymaxBound);
    
    return {xmin, ymin, xmax, ymax};
}


static cv::Mat cropFromBbox(UIImage* image, std::vector<int> bbox) {
    cv::Mat imgMat;
    UIImageToMat(image, imgMat);
    std::vector<int> bounds = {0, 0, imgMat.size[1] - 1, imgMat.size[0] - 1};
    std::vector<int> bboxValid = {
        std::max(bbox[0], bounds[0]),
        std::max(bbox[1], bounds[1]),
        std::min(bbox[2], bounds[2]),
        std::min(bbox[3], bounds[3])};
    
    int cropWidth = bboxValid[2] - bboxValid[0];
    int cropHeight = bboxValid[3] - bboxValid[1];
    std::vector<int> offsets = {bboxValid[0], bboxValid[1]};
    cv::Range rangex(offsets[0], offsets[0] + cropWidth);
    cv::Range rangey(offsets[1], offsets[1] + cropHeight);
    cv::Mat crop(imgMat, {rangey, rangex});
    
    return crop;
}


static cv::Mat makeHeatmap(std::vector<int> xcoords, std::vector<int> ycoords, int sigma=10) {
    cv::Mat heatmap = cv::Mat::zeros(RESIZE, RESIZE, CV_32FC1);
    for(int i = 0; i < 4; i++)
        heatmap.at<float>(xcoords[i], ycoords[i]) = RESIZE;
    cv::GaussianBlur(heatmap, heatmap, cv::Size(0, 0), sigma);
    cv::normalize(heatmap, heatmap, 0, 255, cv::NORM_MINMAX);
    heatmap.convertTo(heatmap, CV_8UC1);
    return heatmap;
}


static cv::Mat crop2FullMask(cv::Mat cropMask, std::vector<int> bbox, int width, int height, int pad) {
    std::vector<int> bounds = {0, 0, width - 1, height - 1};
    std::vector<int> bboxValid = {
        std::max(bbox[0], bounds[0]),
        std::max(bbox[1], bounds[1]),
        std::min(bbox[2], bounds[2]),
        std::min(bbox[3], bounds[3])};
    
    int cropWidth = bboxValid[2] - bboxValid[0] + 1;
    int cropHeight = bboxValid[3] - bboxValid[1] + 1;
    std::vector<int> offsets = {bboxValid[0], bboxValid[1]};
    cv::resize(cropMask, cropMask, cv::Size(cropWidth, cropHeight), cv::INTER_CUBIC);
    cv::Mat mask;
    cv::compare(cropMask, THRES, mask, cv::CMP_GT);
    cv::Mat fullMask = cv::Mat::zeros(height, width, CV_8UC1);
    cv::Rect roiRect = cv::Rect(offsets[0], offsets[1], cropWidth, cropHeight);
    std::cout << mask;
    mask.copyTo(fullMask(roiRect));
    return fullMask;
}


@implementation CVHelper

+ (UIImage*) cropImage: (UIImage*) image withExtremePoints: (NSString*) points {
    std::vector<int> coords;
    split(std::string([points UTF8String]), coords, '|');
    assert(coords.size() == 8);
    std::vector<int> xcoords = {coords[0], coords[2], coords[4], coords[6]};
    std::vector<int> ycoords = {coords[1], coords[3], coords[5], coords[7]};
    
    std::vector<int> bbox = getBbox(image, xcoords, ycoords, PAD);
    cv::Mat cropMat = cropFromBbox(image, bbox);
    cv::Mat resizeMat;
    cv::resize(cropMat, resizeMat, cv::Size(RESIZE, RESIZE), cv::INTER_CUBIC);
    
    int xmin = *std::min_element(xcoords.begin(), xcoords.end());
    int ymin = *std::min_element(ycoords.begin(), ycoords.end());
    for (auto &x : xcoords) {
        x = x - xmin + PAD;
        x = RESIZE * x / cropMat.size[1];
    }
    for (auto &y : ycoords) {
        y = y - ymin + PAD;
        y = RESIZE * y / cropMat.size[0];
    }
    
    cv::Mat heatmap = makeHeatmap(xcoords, ycoords);
    
    cv::Mat inputs(RESIZE, RESIZE, CV_8UC4);
    std::vector<cv::Mat> srcChannels;
    std::vector<cv::Mat> dstChannels;
    
    cv::split(resizeMat, srcChannels);
    dstChannels.push_back(srcChannels[0]);
    dstChannels.push_back(srcChannels[1]);
    dstChannels.push_back(srcChannels[2]);
    dstChannels.push_back(heatmap);
    cv::merge(dstChannels, inputs);
    
    DEXTR net(DEXTR_PATH);
    cv::Mat outputs = net.forward(inputs);
    cv::resize(outputs, outputs, cv::Size(RESIZE, RESIZE));
    
    outputs = -outputs;
    cv::exp(outputs, outputs);
    cv::Mat pred = 1 / (1 + outputs);
    
    cv::Mat mask = crop2FullMask(pred, bbox, image.size.width, image.size.height, PAD);
    std::cout << mask;
    
    UIImage* img = MatToUIImage(resizeMat);
    
    return img;
}

@end
